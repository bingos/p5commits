use 5.012;
no crap;
use Email::Simple;
use POE::Kernel { loop => 'POE::XS::Loop::Poll' };
use POE qw[Component::Client::NNTP];

# <E1RnebJ-0004Py-Oq@camel.ams6.corp.booking.com>

$|=1;

use constant NNTPSERVER => 'nntp.perl.org';
use constant NNTPGROUP  => 'perl.perl5.changes';
use constant BASEURL    => 'http://www.nntp.perl.org/group/perl.perl5.changes';
use constant BASEURL2   => 'http://perl5.git.perl.org/perl.git/commit/';

my $nntp = POE::Component::Client::NNTP->spawn ( 'NNTP-Client', { NNTPServer => NNTPSERVER } );

POE::Session->create(
  package_states => [
    'main' => [qw[_default _start nntp_200 nntp_211 nntp_220]],
  ],
);

$poe_kernel->run();
exit 0;

sub _start {
  my ($kernel,$heap) = @_[KERNEL,HEAP];

  # Our session starts, register to receive all events from poco-client-nntp
  $kernel->post ( 'NNTP-Client' => register => 'all' );
  # Okay, ask it to connect to the server
  $kernel->post ( 'NNTP-Client' => 'connect' );
  undef;
}

sub nntp_200 {
  my ($kernel,$heap,$text) = @_[KERNEL,HEAP,ARG0];

  say $text;

  # Select a group to download from.
  #$kernel->post( 'NNTP-Client' => article => '<E1RnebJ-0004Py-Oq@camel.ams6.corp.booking.com>' );
  #$kernel->post( 'NNTP-Client' => article => '32507' );
  $kernel->post( 'NNTP-Client' => 'group' => NNTPGROUP );
  undef;
}

sub nntp_211 {
  # nntp_211:  '32507 1 32507 perl.perl5.changes'
  my ($kernel,$heap,$text) = @_[KERNEL,HEAP,ARG0];
  $heap->{lastid} = ( split ' ', $text )[0];
  $heap->{firstid} = $heap->{lastid} - 20;
  $kernel->post( 'NNTP-Client' => article => $heap->{firstid} );
  return;
}

sub nntp_220 {
  my ($kernel,$heap,$text,$article) = @_[KERNEL,HEAP,ARG0,ARG1];
  my $post = Email::Simple->new( join("\n", @$article) );
  return unless $post->header('Subject') =~ /^\Q[perl.git]/i;
  (my $subject = $post->header( 'Subject' )) =~ s/\015?\012//g;
  my ($git_describe) = $subject =~ m!(v5.+)$!;

  my $body = $post->body;
  my ($branch,$action);
  ($branch,$action) = $subject =~ m!(annotated tag .+?), (.+?)\.!;
  ($branch,$action) = $body =~ m|In perl.git, the branch ([^ ]+) has been (.+?)\s|
    unless $branch && $action;
  $branch ||= 'nobranch';

  (my $porter = $post->header( 'From' )) =~ s/\015?\012//g;
  $porter ||= '("unknown")';
  my ($pname) = $porter =~ /\("(.+)"\)/;

  my $msg = "$pname pushed to $branch ($git_describe):";
  unless ( $action =~ m!(deleted|created)! ) {
    my $log = 0;
    my $state = {};
    my $ignore = 0;
    foreach my $line ( @{ $article } ) {
      if ( $log ) {
        if ( $line =~ /^----------------/ ) {
          if ( $state->{msg} ) {
            $msg .= _build_msg( $state );
            $state = { };
          }
          last;
        }
        if ( $line =~ /commit\s+([0-9a-f]{8})/ ) {
          if ( $state->{msg} ) {
            $msg .= _build_msg( $state );
            $state = { };
          }
          $state->{sha1} = $1;
          next;
        }
        if ( $line =~ /Author:\s+(.+) <.+>/ ) {
          $state->{author} = $1;
          next;
        }
        if ( $line =~ /Date:\s+/ ) {
          $state->{date} = 'yes';
          next;
        }
        next if $line =~ /^\s*$/;
        next if $state->{msg};
        if ( $state->{date} and $line =~ /^\s*(.+)$/ ) {
          $state->{msg} = $1 || 'no commit message found.';
          next;
        }
      }
      $log = 1 if $line =~ /^- Log -/;
    }
  }
  else {
    $msg .= " $action";
  }

=for comment

  while ( $body =~ /\015?\012commit\s+([0-9a-f]{8})/g ) {
      my $sha1 = $1;

      pos( $body ) = index( $body, 'Author:', pos( $body ) );
      my ($author) = $body =~ m/\GAuthor:\s+(.+) <.+>\015?\012/;

      pos( $body ) = index( $body, 'Date', pos( $body ) );
      my ($commitmsg) = $body =~ m/\GDate:.+\s+(.+)/;
      $commitmsg ||= 'no commit message found.';

      my $url = BASEURL2 . $sha1;
      $msg .= " $author: $commitmsg; $url";
  }

=cut

  say $msg;
  say '###################';
  return if ++$heap->{firstid} > $heap->{lastid};
  $kernel->post( 'NNTP-Client' => article => $heap->{firstid} );
  return;
}

sub _build_msg {
  my $state = shift;
  return ' ' . $state->{author} . ': ' . $state->{msg} . '; ' . BASEURL2 . $state->{sha1};
}

# We registered for all events, this will produce some debug info.
sub _default {
   my ($event, $args) = @_[ARG0 .. $#_];
   my @output = ( "$event: " );

   for my $arg (@$args) {
      if ( ref $arg eq 'ARRAY' ) {
         push( @output, '[' . join(', ', @$arg ) . ']' );
      }
      else {
         push ( @output, "'$arg'" );
      }
   }
   print join ' ', @output, "\n";
   return 0;
}

