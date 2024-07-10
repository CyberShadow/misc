use strict;
use Fcntl qw(F_SETLK F_WRLCK SEEK_SET);
my $file = $ARGV[0];
open(my $fh, '>>', $file) or die "Could not open '$file' - $!";
# flock($fh, LOCK_EX | LOCK_NB) or die "Could not lock '$file' - $!";
my $pack = pack('s s x![q] q q i', F_WRLCK, SEEK_SET, 0, 0, $$);
fcntl($fh, F_SETLK, $pack) or die "Could not lock '$file' - $!";
print "locked\n"; STDOUT->flush;
while (<STDIN>) {print;}
close($fh) or die "Could not write '$file' - $!";
