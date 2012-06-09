package Tube::File::Cursor;

use Moo;

# ABSTRACT: file cursor

use MooX::Types::MooseLike::Base qw(:all);

use Params::Validate qw(:all);
use Carp;
use autodie;

has posfile => (
    is => 'ro',
    isa => Str,
    required => 1,
);

# TODO - role?
has read_only => (
    is => 'ro',
    isa => Bool,
    default => 0,
);

sub position {
    my $self = shift;
    return 0 unless -e $self->posfile;
    open my $fh, '<', $self->posfile;
    my $position = join '', <$fh>;
    chomp $position;
    unless ($position =~ /^\d+$/) {
        die "Invalid position in posfile ".$self->posfile;
    }
    return $position;
}

sub set_position {
    my $self = shift;
    my ($position) = validate_pos(@_, { type => SCALAR, regex => qr/^\d+$/ });
    croak "Cursor is read-only" if $self->read_only;

    my $posfile = $self->posfile;
    my $posfile_new = "$posfile.new";
    open my $fh, '>', $posfile_new;
    print {$fh} "$position\n"; # adding \n for the better readability
    close $fh; # TODO - should we fsync? at least optionally?
    rename $posfile_new => $posfile;
    return;
}

1;
