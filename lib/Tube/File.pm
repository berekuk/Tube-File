package Tube::File;

# TODO - namespace::autoclean?
# I love namespace::autoclean, but it's too heavy-weight to use here -- mmcleric

use Moo;
with 'Tube::Storage'; # waiting for Moo release which allows multiple role application
with 'Tube::Role::Owned';
with 'Tube::Role::Description';

use MooX::Types::MooseLike::Base qw(:all);

# ABSTRACT: file storage

=head1 SYNOPSIS

    $storage = Tube::File->new($filename);
    $in = $storage->in($posfile);

=head1 METHODS

=over

=cut

use Params::Validate qw(:all);

use Carp;
use Fcntl qw(SEEK_SET SEEK_CUR SEEK_END);
use IO::Handle;
use Yandex::Lockf;
use Tube::File::In;

use autodie;

=item B<new($file, [$options])>

Create new object. C<$file> should be a name of any writable file into which lines will be appended.

If C<$file> does not yet exist, it will be created.

Options can contains the following keys:

=over

=item I<lock> (default = 1)

Get lock on each write (useful when many processes writes in one file).

=item I<reopen> (default = 0)

Reopen file on each write (useful for files, which can be rotated).

=item I<safe> (default = 0)

Truncate file to the last endline (useful when your unit for writings is a single lines
and you don't want to have a hanging lines in your log in case of failure).
If C<reopen> is true, then file checks on each flush, otherwise it will be checked only at
first flush.

=back

=cut
sub BUILDARGS {
    my $class = shift;
    my ($file, $p) = validate_pos(@_, 1, { type => HASHREF, default => {} });
    return { file => $file, %$p };
}

has file => (
    is => 'ro',
    isa => Str,
    required => sub { 1 },
);

has lock => (
    is => 'ro',
    isa => Bool,
    default => sub { 1 },
);

has safe => (
    is => 'ro',
    isa => Bool,
    default => sub { 1 },
);

has reopen => (
    is => 'ro',
    isa => Bool,
    default => sub { 0 },
);

sub description {
    my $self = shift;
    return "file: ".$self->file;
}

sub _open {
    my ($self) = @_;

    unless (-f $self->file) {
        # touch file, so we can open it for rw later
        # there is still a small race - file can be renamed after this open and before the second open
        open(my $f, '>>', $self->file);
        close($f);
    }

    my $mode = $self->safe ? "+<" : ">>";

    open($self->{fh}, $mode, $self->file);
    my $lock = $self->_lockf;
    if ($self->safe) {
        $self->_truncate;
    }

    return $lock;
}

sub _lockf {
    my $self = shift;
    return unless ($self->lock);
    die "no filehandle" unless ($self->{fh});
    my $lock = lockf($self->{fh});
    return $lock;
}

sub _truncate {
    my $self = shift;

    # return if it is an empty file
    my $f = $self->{fh};
    sysseek($f, 0, SEEK_END);
    my $fsize = sysseek($f, 0, SEEK_CUR);
    return if ($fsize == 0);

    # initially we check only last byte and if it is a "\n",
    # then it's all ok
    sysseek($f, -1, SEEK_END);
    my $eof_byte = _sysread($f, 1);
    return if ($eof_byte eq "\n");

    my $cur_pos = $fsize;
    while (1) {
        # we have reached beginning of the file and haven't found "\n",
        # so we truncate file entirely
        if ($cur_pos == 0) {
            sysseek($f, 0, SEEK_SET);
            $f->truncate(0);
            last;
        }

        # we read file in reverse order by chunks with $read_portion size.
        # if current position is near of the beginning, we read
        # all remained bytes from the start of the file
        my $read_portion = 1024;
        $read_portion = $cur_pos if ($cur_pos < $read_portion);
        sysseek($f, $cur_pos - $read_portion, SEEK_SET);
        my $s = _sysread($f, $read_portion);

        # try to find last index of "\n" in the chunk
        my $index;
        while (1) {
            my $index_pos = 0;
            $index_pos = $index + 1 if (defined($index));
            my $new_index = index($s, "\n", $index_pos);
            if ($new_index < 0) {
                last;
            } else {
                $index = $new_index;
            }
        }

        # if found, then we can truncate file
        if (defined($index)) {
            my $new_pos = $cur_pos - $read_portion + $index +1;
            sysseek($f, $new_pos, SEEK_SET);
            $f->truncate($new_pos);
            last;
        }

        # else try to read chunk nearer to the beginning of file
        $cur_pos -= $read_portion;
    }
}

sub _sysread {
    my ($f, $length) = @_;

    my $line;
    my $offset = 0;
    my $left = $length;
    while ($left) {
        my $bytes = $f->sysread($line, $left, $offset);
        if (not defined $bytes) {
            die "sysread failed: $!";
        } elsif ($bytes == 0) {
            die "sysread no progress";
        } else {
            $offset += $bytes;
            $left   -= $bytes;
        }
    }

    return $line;
}

sub _write {
    my ($self) = @_;
    my $left = length $self->{data};
    my $offset = 0;
    while ($left) {
        my $bytes = $self->{fh}->syswrite($self->{data}, $left, $offset);
        if (not defined $bytes) {
            die "syswrite failed: $!";
        } elsif ($bytes == 0) {
            die "syswrite no progress";
        } else {
            $offset += $bytes;
            $left -= $bytes;
        }
    }
    delete $self->{data};
}

sub _flush {
    my ($self) = @_;
    return unless defined $self->{data};

    my $lock;
    if (!$self->{fh} || $self->reopen) {
        $lock = $self->_open;
    } else {
        $lock = $self->_lockf;
        sysseek($self->{fh}, 0, SEEK_END) if $self->safe;
    }

    $self->_write();
}

=item B<write($line)>

Write a new line into the file.

=cut
sub write {
    my ($self, $line) = @_;

    $self->write_chunk([$line]);
}

=item B<write_chunk($chunk)>

Write multiple lines into the file.

=cut
sub write_chunk {
    my ($self, $chunk) = @_;
    croak "write_chunk method expects arrayref" unless ref($chunk) eq 'ARRAY'; # can chunks be blessed into something?
    return unless @$chunk;
    for my $line (@$chunk) {
        die "invalid line $line" if ($line !~ /\n\z/);
        if (defined $self->{data}) {
            $self->{data} .= $line;
        }
        else {
            $self->{data} = $line;
        }
    }
    if (length($self->{data}) > 1_000) {
        $self->_flush;
    }
    return; # TODO - what useful data can we return?
}

sub commit {
    my ($self) = @_;
    $self->_flush;
}

=item B<in($cursor)>

Construct stream object from an L<Tube::File::Cursor> object.

=cut
sub in {
    my $self = shift;
    my ($cursor) = validate_pos(@_, {isa => 'Tube::File::Cursor'});

    return Tube::File::In->new(cursor => $cursor, file => $self->file);
}

sub owner {
    my ($self) = @_;
    if (-e $self->file) {
        return scalar getpwuid( (stat($self->file))[4] );
    }
    else {
        return scalar getpwuid($>);
    }
}

=back

=cut

1;
