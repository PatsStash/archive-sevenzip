package Archive::SevenZip;
use strict;
use Carp qw(croak);
use Encode qw( decode encode );
use File::Basename qw(dirname basename);
use Archive::SevenZip::Entry;
use File::Temp 'tempfile';
use File::Copy;
use IPC::Run;

=head1 NAME

Archive::SevenZip - Read/write 7z , zip , ISO9960 and other archives

=head1 SYNOPSIS

  my $ar = Archive::SevenZip->new(
      find => 1,
      archivename => $archivename,
      verbose => $verbose,
  );

  for my $entry ( $ar->list ) {
      my $target = join "/", "$target_dir", $entry->basename;
      $ar->extractMember( $entry->fileName, $target );
  };

=head1 METHODS

=cut

use vars qw(%sevenzip_charsetname %class_defaults $VERSION);
$VERSION= '0.01';

%sevenzip_charsetname = (
    'UTF-8' => 'UTF-8',
    'Latin-1' => 'WIN',
    'ISO-8859-1' => 'WIN',
    '' => 'DOS', # dunno what the appropriate name would be
);

%class_defaults = (
    '7zip' => '7z',
    fs_encoding => 'UTF-8',
    default_options => [ "-y", "-bd" ],
    type => 'zip',
);

=head2 C<< Archive::SevenZip->find_7z_executable >>

Finds the 7z executable in the path or in C<< $ENV{ProgramFiles} >>
or C<< $ENV{ProgramFiles(x86)} >>. This is called
when a C<< Archive::SevenZip >> instance is created with the C<find>
parameter set to 1.

=cut

sub find_7z_executable {
    my($class) = @_;
    my $old_default = $class_defaults{ '7zip' };
    my $envsep = $^O =~ /MSWin/ ? ';' : ':';
    my @search = split /$envsep/, $ENV{PATH};
    if( $^O =~ /MSWin/i ) {
        push @search, map { "$_\\7-Zip" } ($ENV{'ProgramFiles'}, $ENV{'ProgramFiles(x86)'});
    };
    my $found = $class->version;
    
    while( ! $found and @search) {
        my $dir = shift @search;
        $class_defaults{'7zip'} = "$dir/7z";
        $found = $class->version;
    };
    
    if( ! $found) {
        $class_defaults{ '7zip' } = $old_default;
    };
    
    return defined $found ? $found : ()
}

=head2 C<< Archive::SevenZip->new >>

  my $ar = Archive::SevenZip->new( $archivename );

  my $ar = Archive::SevenZip->new(
      archivename => $archivename,
      find => 1,
  );

Creates a new class instance.

C<find> - will search C<$ENV{PATH}>, 

=cut

sub new {
    my( $class, %options);
    if( @_ == 2 ) {
        ($class, $options{ archivename }) = @_;
    } else {
        ($class, %options) = @_;
    };
    
    if( $options{ find }) {
        $class->find_7z_executable();
    };
    
    for( keys %class_defaults ) {
        $options{ $_ } //= $class_defaults{ $_ };
    };
    
    bless \%options => $class
}

sub version {
    my( $self_or_class, %options) = @_;
    for( keys %class_defaults ) {
        $options{ $_ } //= $class_defaults{ $_ };
    };
    my $self = ref $self_or_class ? $self_or_class : $self_or_class->new( %options );
    
    
    my $cmd = $self->get_command(
        command => '',
        archivename => undef,
    );
    my $fh = $self->run($cmd, binmode => ':raw');
    local $/ = "\n";
    my @output = <$fh>;
    if( @output > 5) {
        $output[1] =~ /^7-Zip\s+.*?(\d+\.\d+)\s+Copyright/
            or return undef;
        return $1;
    } else {
        return undef
    }
}

=head2 C<< $ar->open >>

  my @entries = $ar->open;
  for my $entry (@entries) {
      print $entry->name, "\n";
  };

Lists the entries in the archive. A fresh archive which does not
exist on disk yet has no entries. The returned entries
are L<Archive::SevenZip::Entry> instances.

This method will one day move to the Path::Class-compatibility
API.

=cut
# Iterate over the entries in the archive
# Path::Class API
sub open {
    my( $self )= @_;
    my @contents = $self->list();
}

=head2 C<< $ar->list >>

  my @entries = $ar->list;
  for my $entry (@entries) {
      print $entry->name, "\n";
  };

Lists the entries in the archive. A fresh archive which does not
exist on disk yet has no entries. The returned entries
are L<Archive::SevenZip::Entry> instances.

This method will one day move to the Archive::Zip-compatibility
API.

=cut

# Archive::Zip API
sub list {
    my( $self, %options )= @_;
    
    if( ! defined ($options{archivename} // $self->{archivename})) {
        # We are an archive that does not exist on disk yet
        return
    };
    my $cmd = $self->get_command( command => "l", options => ["-slt"], %options );
    
    my $fh = $self->run($cmd, encoding => $options{ fs_encoding } );
    my @output = <$fh>;
    chomp @output;
    
    my %results = (
        header => [],
        archive => [],
    );
    
    # Get/skip header
    while( @output and $output[0] !~ /^--$/ ) {
        push @{ $results{ header }}, shift @output;
    };
    
    # Get/skip archive information
    while( @output and $output[0] !~ /^----------$/ ) {
        push @{ $results{ archive }}, shift @output;
    };
    
    if( $output[0] =~ /^----------$/ ) {
        shift @output;
    } else {
        warn "Unexpected line in 7zip output, hope that's OK: [$output[0]]";
    };

    my @members;

    # Split entries
    my %entry_info;
    while( @output ) {
        my $line = shift @output;
        if( $line =~ /^([\w ]+) =(?: (.*)|)$/ ) {
            $entry_info{ $1 } = $2;
        } elsif($line =~ /^\s*$/) {
            push @members, Archive::SevenZip::Entry->new(
                %entry_info,
                _Container => $self,
            );
            %entry_info = ();
        } else {
            croak "Unknown file entry [$line]";
        };
    };
    
    return @members
}
*members = \&list;

=head2 C<< $ar->openMemberFH >>

  my $fh = $ar->openMemberFH('test.txt');
  while( <$fh> ) {
      print "test.txt: $_";
  };

Reads the uncompressed content of the member from the archive.

This method will one day move to the Archive::Zip-compatibility
API.

=cut

sub openMemberFH {
    my( $self, %options );
    if( @_ == 2 ) {
        ($self,$options{ membername })= @_;
    } else {
        ($self,%options) = @_;
    };
    defined $options{ membername } or croak "Need member name to extract";
    
    my $cmd = $self->get_command( command => "e", options => ["-so"], members => [$options{membername}] );
    my $fh = $self->run($cmd, encoding => $options{ encoding }, binmode => $options{ binmode } );
    return $fh
}

sub content {
    my( $self, %options ) = @_;
    my $fh = $self->openMemberFH( %options );
    local $/;
    <$fh>
}
=head2 C<< $ar->extractMember >>

  $ar->extractMember('test.txt' => 'extracted_test.txt');

Extracts the uncompressed content of the member from the archive.

This method will one day move to the Archive::Zip-compatibility
API.

=cut

# Archive::Zip API
sub extractMember {
    my( $self, $memberOrName, $extractedName ) = @_;
    $extractedName //= $memberOrName;
    
    my %options = %$self;
    
    my $target_dir = dirname $extractedName;
    my $target_name = basename $extractedName;
    my $cmd = $self->get_command(
        command     => "e",
        archivename => $options{ archivename }, 
        members     => [ $memberOrName ],
        options     => [ "-o$target_dir" ],
    );
    my $fh = $self->run($cmd, encoding => $options{ encoding } );
    
    while( <$fh>) {
        warn $_ if $self->{verbose};
    };
    if( basename $memberOrName ne $target_name ) {
        rename "$target_dir/" . basename($memberOrName) => $extractedName
            or croak "Couldn't move '$memberOrName' to '$extractedName': $?";
    };
    
};

sub add_quotes {
    map {
        defined $_ && /\s/ ? qq{"$_"} : $_
    } @_
};

sub get_command {
    my( $self, %options )= @_;
    $options{ members } ||= [];
    $options{ archivename } //= $self->{ archivename };
    $options{ fs_encoding } //= $self->{ fs_encoding } // $class_defaults{ fs_encoding };
    $options{ default_options } //= $self->{ default_options } // $class_defaults{ default_options };
    
    my $charset = $sevenzip_charsetname{ $options{ fs_encoding }}
        or croak "Unknown filesystem encoding '$options{ fs_encoding }'";
    for(@{ $options{ members }}) {
        $_ = encode $options{ fs_encoding }, $_;
    };

    # Now quote what needs to be quoted
    for( @{ $options{ options }}, @{ $options{ members }}, $options{ archivename }, "$self->{ '7zip' }") {
    };

    return [grep {defined $_}
        add_quotes($self->{ '7zip' }),
        @{ $options{ default_options }},
        $options{ command },
        "-scs$charset",
        add_quotes( @{ $options{ options }} ),
        add_quotes( $options{ archivename } ),
        add_quotes( @{ $options{ members }} ),
    ];
}

sub run {
    my( $self, $cmd, %options )= @_;
    
    my $mode = '-|';
    if( defined $options{ stdin }) {
        $mode = '|-';
    };

    my $fh;
    if( $^O =~ /MSWin/i ) {
        #warn "Opening [@$cmd |]";
        my @cmd = @$cmd;
        
        my $str;
        my $redirect_stderr = '2>nul:';
        if( $self->{verbose} ) {
            $redirect_stderr = '';
        };
        
        if( '|-' eq $mode ) {
            $str = "| @cmd $redirect_stderr"
        } else {
            $str = "@cmd $redirect_stderr |"
        };

        #warn "Opening [$str]";
        
        # Yees, list-open for Win32 is in 5.24, but I want to use it
        # elsewhere too. So, no list-open for you!
        CORE::open( $fh, $str )
            or croak "Couldn't launch [$mode @cmd]: $!/$?";
    } else {
        CORE::open( $fh, $mode, @$cmd)
            or croak "Couldn't launch [$mode @$cmd]: $!/$?";
    };
    if( $options{ encoding }) {
        binmode $fh, ":encoding($options{ encoding })";
    } elsif( $options{ binmode } ) {
        binmode $fh, $options{ binmode };
    };
    
    if( $options{ stdin }) {
        print {$fh} $options{ stdin };
        close $fh;
    } elsif( $options{ skip }) {
        for( 1..$options{ skip }) {
            # Read that many lines
            local $/ = "\n";
            scalar <$fh>;
        };
    };
    
    $fh;
}

sub archive_or_temp {
    my( $self ) = @_;
    if( ! defined $self->{archivename} ) {
        $self->{is_tempfile} = 1;
        (my( $fh ),$self->{archivename}) = tempfile( ); # SUFFIX => ".$self->{type}", 
        close $fh;
    };
    $self->{archivename}
};

sub add_scalar {
    my( $self, $name, $scalar )= @_;
    
    # Only supports 7z archive type?!
    my $cmd = $self->get_command(
        command => 'a',
        archivename => $self->archive_or_temp,
        options => [sprintf( '-si%s', $name ), "-t7z" ],
    );
    my $fh = $self->run( $cmd,
        binmode => ':raw',
        stdin => $scalar,
    );
};


sub add {
    my( $self, %options )= @_;
    
    my @items = @{ delete $options{ items } || [] };
    for my $item (@items) {
        if( ! ref $item ) {
            $item = [ $item, $item ];
        };
        my( $name, $storedName ) = @$item;

        if( $name ne $storedName ) {
            # We need to pipe to 7zip from stdin
        } else {
            # 7zip can read the file from disk
            # Write the name to a tempfile to be read by 7zip for batching
        };
        my $fh = $self->run( command => 'a',
        );
    };
};

package Archive::SevenZip::API::ArchiveZip;
use strict;
use Carp qw(croak);
use Encode qw( decode encode );
use File::Basename qw(dirname basename);
use File::Copy;

sub new {
    my( $class, %options )= @_;
    $options{ sevenZip } = Archive::SevenZip->new();
    bless \%options => $class;
};

sub sevenZip { $_[0]->{sevenZip} }

=head1 NAME

Archive::SevenZip::API::ArchiveZip - Archive::Zip compatibility API

=cut

sub writeToFileNamed {
    my( $self, $targetName )= @_;
    copy( $self->sevenZip->{archivename}, $targetName );
}

sub addFileOrDirectory {
    my($self, $name, $newName, $compressionLevel) = @_;
    $newName //= $name;
    $self->sevenZip->add(
        items => [ [$name, $newName] ],
        compression => $compressionLevel
    );
}

sub addString {
}

#my $member = $zip->addDirectory($memberName);
sub addDirectory {
    # Create just a directory name
}

package Path::Class::Archive::Handle;
use strict;

=head1 NAME

Path::Class::Archive - treat archives as directories

=cut

package Path::Class::Archive;

1;

__END__

=head1 CAUTION

This module tries to mimic the API of L<Archive::Zip> in some cases
and in other cases, the API of L<Path::Class>. It is also a very rough
draft that just happens to be doing what I need, mostly extracting
files.

=head1 REPOSITORY

The public repository of this module is 
L<http://github.com/Corion/archive-sevenzip>.

=head1 SUPPORT

The public support forum of this module is
L<https://perlmonks.org/>.

=head1 BUG TRACKER

Please report bugs in this module via the RT CPAN bug queue at
L<https://rt.cpan.org/Public/Dist/Display.html?Name=HTML-Rebase>
or via mail to L<archive-sevenzip-Bugs@rt.cpan.org>.

=head1 AUTHOR

Max Maischein C<corion@cpan.org>

=head1 COPYRIGHT (c)

Copyright 2015 by Max Maischein C<corion@cpan.org>.

=head1 LICENSE

This module is released under the same terms as Perl itself.

=cut