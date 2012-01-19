use 5.012;
use strict;
use warnings;
use Email::Simple;
use POE::Kernel { loop => 'POE::XS::Loop::Poll' };
use if $^O eq 'linux', 'POE::Kernel'=> { loop => 'POE::XS::Loop::EPoll' };
use unless $^O eq 'linux', 'POE::Kernel' => { loop => 'POE::XS::Loop::Poll' };
use POE qw(Component::IRC);
use POE::Component::IRC::Common qw( :ALL );
use POE::Component::IRC::Plugin::Connector;
use POE::Component::Client::NNTP::Tail;

use constant NNTPSERVER => 'nntp.perl.org';
use constant NNTPGROUP  => 'perl.perl5.changes';
use constant BASEURL    => 'http://www.nntp.perl.org/group/perl.perl5.changes';
use constant BASEURL2   => 'http://perl5.git.perl.org/perl.git/commit/';

use constant NICKNAME   => 'p5commits';
use constant IRCSERVER  => 'irc.perl.org';
use constant IRCPORT    => '6667';
use constant IRCUSER    => 'p5p';
use constant IRCNAME    => 'p5commits bot <see BinGOs>';
use constant CHANNEL    => '#p5p';

$|=1;

my $irc = POE::Component::IRC->spawn( debug => 0 );

POE::Component::Client::NNTP::Tail->spawn(
   NNTPServer  => NNTPSERVER,
   Group       => NNTPGROUP,
);

POE::Session->create(
    package_states => [
	    'main' => [ qw(_start irc_001 irc_join _default _header _article) ],
    ],
    options => { trace => 0 },
);

$poe_kernel->run();
exit 0;

sub _start {
  my ($kernel, $heap, $session) = @_[KERNEL, HEAP, SESSION];
  $kernel->post( NNTPGROUP, 'register', '_header' );
  $irc->yield( register => 'all' );
  $irc->plugin_add( 'Connector', POE::Component::IRC::Plugin::Connector->new() );
  $irc->yield( connect => {
    Nick     => NICKNAME,
    Server   => IRCSERVER,
    Port     => IRCPORT,
    Username => IRCUSER,
    Ircname  => IRCNAME,
  } );
  return;
}

sub irc_001 {
  $irc->yield( 'join', CHANNEL );
  return;
}

sub irc_join {
  my ($nickhost,$channel) = @_[ARG0,ARG1];
  return;
}

sub _header {
  my ($kernel,$id,$article) = @_[KERNEL,ARG0,ARG1];
  my $post = Email::Simple->new( join("\n", @$article) );
  return unless $post->header('Subject') =~ /^\Q[perl.git]/i;
  $kernel->post( $_[SENDER], 'get_article', $id, '_article' );
  return;
}

sub _article {
  my ($kernel,$id,$article) = @_[KERNEL,ARG0,ARG1];
  my $post = Email::Simple->new( join("\n", @$article) );
  return unless $post->header('Subject') =~ /^\Q[perl.git]/i;
  (my $subject = $post->header( 'Subject' )) =~ s/\015?\012//g;
  my ($git_describe) = $subject =~ m!(v5.+)$!;

  my $body = $post->body;
  my ($branch,$action) = $body =~ m|In perl.git, the branch ([^ ]+) has been ([^ ]+)|;
  $branch ||= 'nobranch';

  (my $porter = $post->header( 'From' )) =~ s/\015?\012//g;
  $porter ||= '("unknown")';
  my ($pname) = $porter =~ /\("(.+)"\)/;

  my $msg = "$pname pushed to $branch ($git_describe):";
  if ( $action eq 'deleted' ) {
    $msg .= " $action";
    say $msg;
    $irc->yield( 'ctcp', CHANNEL, "ACTION $msg" );
    return;
  }
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
  say $msg;
  $irc->yield( 'ctcp', CHANNEL, "ACTION $msg" );
  return;
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
