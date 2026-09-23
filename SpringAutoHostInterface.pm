# Object-oriented Perl module implementing a callback-based interface to
# communicate with SpringRTS engine through autohost interface.
#
# Copyright (C) 2008-2026  Yann Riou <yaribzh@gmail.com>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.
#

package SpringAutoHostInterface;

use strict;
use warnings;

use Encode qw'decode encode';
use IO::Socket::INET;
use Storable "dclone";

use base 'Exporter';

our %EXPORT_TAGS = (
  srvState => [qw'SRV_STATE_NOT_RUNNING SRV_STATE_SERVER_STARTED SRV_STATE_GAME_STARTED SRV_STATE_GAME_OVER'],
  cliState => [qw'CLI_STATE_LOADING CLI_STATE_CONNECTED CLI_STATE_CONNECTION_LOST CLI_STATE_LEFT CLI_STATE_KICKED'],
  rdyState => [qw'RDY_STATE_NOT_PLACED RDY_STATE_PLACED RDY_STATE_READY_BY_ENGINE RDY_STATE_READY_BY_LUA'],
  msgDest => [qw'MSG_DEST_ALLIES MSG_DEST_SPECTATORS MSG_DEST_EVERYONE MSG_DEST_SERVER'],
  luaScript => [qw'LUA_SCRIPT_RULES LUA_SCRIPT_GAIA LUA_SCRIPT_UI'],
  luaMode => [qw'LUA_MODE_ALL LUA_MODE_ALLIES LUA_MODE_SPECTATORS'],
    );

push(@{$EXPORT_TAGS{all}},@{$EXPORT_TAGS{$_}}) foreach(keys %EXPORT_TAGS);
Exporter::export_ok_tags('all');

use SimpleLog;

# Internal constants
use constant {
  MTU_LOCALHOST => 65536,

  NETMSG_LUAMSG => 50,

  MSGSIZE_EXCLUDES_CMDCODE => 0,
  MSGSIZE_INCLUDES_CMDCODE => 1,
};

# Exported constants
use constant {
  SRV_STATE_NOT_RUNNING => 0,
  SRV_STATE_SERVER_STARTED => 1,
  SRV_STATE_GAME_STARTED => 2,
  SRV_STATE_GAME_OVER => 3,
  
  CLI_STATE_LOADING => -2,
  CLI_STATE_CONNECTED => -1,
  CLI_STATE_CONNECTION_LOST => 0,
  CLI_STATE_LEFT => 1,
  CLI_STATE_KICKED => 2,

  RDY_STATE_NOT_PLACED => -1,
  RDY_STATE_PLACED => 0,
  RDY_STATE_READY_BY_ENGINE => 1,
  RDY_STATE_READY_BY_LUA => 2,

  MSG_DEST_ALLIES => 252,
  MSG_DEST_SPECTATORS => 253,
  MSG_DEST_EVERYONE => 254,
  MSG_DEST_SERVER => 255,

  LUA_SCRIPT_RULES => 100,
  LUA_SCRIPT_GAIA => 300,
  LUA_SCRIPT_UI => 2000,

  LUA_MODE_ALL => 0,
  LUA_MODE_ALLIES => ord('a'),
  LUA_MODE_SPECTATORS => ord('s'),
};

# Internal data ###############################################################

our $VERSION='0.15';

my %commandTypes = (
  0 => {
    name => 'SERVER_STARTED',
    paramSize => 0,
  },
  1 => {
    name => 'SERVER_QUIT',
    paramSize => 0,
  },
  2 => {
    name => 'SERVER_STARTPLAYING',
    minParamSize => 20,
    paramTemplate => 'V H32 a*',     # (uint32 msgSize,) uint8[16] gameId, char[] demoName
    utf8ParamIdx => 1,
    msgSizeMode => MSGSIZE_INCLUDES_CMDCODE,
  },
  3 => {
    name => 'SERVER_GAMEOVER',
    minParamSize => 2,
    paramTemplate => 'C*',           # (uint8 msgSize,) uint8 playerNum, uint8[] winningAllyTeamss
    msgSizeMode => MSGSIZE_INCLUDES_CMDCODE,
  },
  4 => {
    name => 'SERVER_MESSAGE',
    minParamSize => 1,
    utf8ParamIdx => 0,               # char[] message
  },
  5 => {
    name => 'SERVER_WARNING',
    minParamSize => 1,
    utf8ParamIdx => 0,               # char[] warningMessage
  },
  10 => {
    name => 'PLAYER_JOINED',
    minParamSize => 2,
    paramTemplate => 'C a*',         # uint8 playerNum, char[] name
    utf8ParamIdx => 1,
  },
  11 => {
    name => 'PLAYER_LEFT',
    paramSize => 2,
    paramTemplate => 'C2',           # uint8 playerNum, uint8 reason
  },
  12 => {
    name => 'PLAYER_READY',
    paramSize => 2,
    paramTemplate => 'C2',           # uint8 playerNum, uint8 state
  },
  13 => {
    name => 'PLAYER_CHAT',
    minParamSize => 3,
    paramTemplate => 'C2 a*',        # uint8 playerNum, uint8 destination, char[] text
    utf8ParamIdx => 2,
  },
  14 => {
    name => 'PLAYER_DEFEATED',
    paramSize => 1,
    paramTemplate => 'C',            # uint8 playerNum
  },
  20 => {
    name => 'GAME_LUAMSG',
    minParamSize => 7,
    paramTemplate => 'C v C v C a*', # (uint8 NETMSG_LUAMSG, uint16 msgSize,) uint8 playerNum, uint16 script, uint8 mode, uint8[] data
    msgSizeMode => MSGSIZE_EXCLUDES_CMDCODE,
  },
  60 => {
    name => 'GAME_TEAMSTAT',
    paramSize => 81,
    paramTemplate => 'C l< f12 l<7', # uint8 teamNum, TeamStatistics stats
  },
    );

my %commandHandlers = (
  SERVER_STARTED => \&serverStartedHandler,
  SERVER_QUIT => \&serverQuitHandler,
  SERVER_STARTPLAYING => \&serverStartPlayingHandler,
  SERVER_GAMEOVER => \&serverGameOverHandler,
  SERVER_MESSAGE => \&serverMessageHandler,
  PLAYER_JOINED => \&playerJoinedHandler,
  PLAYER_LEFT => \&playerLeftHandler,
  PLAYER_READY => \&playerReadyHandler,
  PLAYER_DEFEATED => \&playerDefeatedHandler
);

# Constructor #################################################################

sub new {
  my ($objectOrClass,%params) = @_;
  my $class = ref($objectOrClass) || $objectOrClass;
  my $p_conf = {
    autoHostPort => 8454,
    simpleLog => undef,
    warnForUnhandledMessages => 1
  };
  foreach my $param (keys %params) {
    if(grep(/^$param$/,(keys %{$p_conf}))) {
      $p_conf->{$param}=$params{$param};
    }else{
      if(! (defined $p_conf->{simpleLog})) {
        $p_conf->{simpleLog}=SimpleLog->new(prefix => "[SpringAutoHostInterface] ");
      }
      $p_conf->{simpleLog}->log("Ignoring invalid constructor parameter ($param)",2)
    }
  }
  if(! (defined $p_conf->{simpleLog})) {
    $p_conf->{simpleLog}=SimpleLog->new(prefix => "[SpringAutoHostInterface] ");
  }

  my $self = {
    conf => $p_conf,
    autoHostSock => undef,
    state => SRV_STATE_NOT_RUNNING,
    gameId => '',
    demoName => '',
    players => {},
    callbacks => {},
    preCallbacks => {},
    connectingPlayer => { name => '', version => '', address => '' }
  };

  bless ($self, $class);
  return $self;
}

# Accessors ###################################################################

sub getVersion {
  return $VERSION;
}

sub getState {
  my $self = shift;
  return $self->{state};
}

sub getPlayerName {
  my ($self,$playerNb)=@_;
  return exists $self->{players}{$playerNb} ? $self->{players}{$playerNb}{name} : undef;
}

sub getPlayer {
  my ($self,$name)=@_;
  foreach my $playerNb (keys %{$self->{players}}) {
    return $self->{players}{$playerNb} if($self->{players}{$playerNb}{name} eq $name);
  }
  return {};
}

sub getPlayerByNum {
  my ($self,$playerNb)=@_;
  return $self->{players}{$playerNb};
}

sub getPlayers {
  my $self = shift;
  return dclone($self->{players});
}

sub getPlayersByNames {
  my $self = shift;
  my %playersByNames;
  foreach my $playerNb (keys %{$self->{players}}) {
    $playersByNames{$self->{players}{$playerNb}{name}}=dclone($self->{players}{$playerNb});
  }
  return \%playersByNames;
}

# Debugging method ############################################################

sub dumpState {
  my $self=shift;
  my %conf=%{$self->{conf}};
  my $sl=$conf{simpleLog};
  $sl->log("-------------------------- DUMPING STATE ----------------------------",5);
  $sl->log("State:$self->{state}",5);
  $sl->log("Players:",5);
  foreach my $pId (keys %{$self->{players}}) {
    my $pHash=$self->{players}{$pId};
    $sl->log("  $pId: name=$pHash->{name},ready=$pHash->{ready},lost=$pHash->{lost},disconnectCause=$pHash->{disconnectCause},version=$pHash->{version}",5);
  }
  $sl->log("--------------------------- END OF DUMP -----------------------------",5);
}

sub paramToString { ref $_[0] eq 'ARRAY' ? '['.join(',',@{$_[0]}).']' : $_[0] }

# Marshallers/unmarshallers ###################################################

sub unmarshallCommand {
  my ($self,$marshalled)=@_;

  my $sl=$self->{conf}{simpleLog};

  my $commandCode=unpack('C',substr($marshalled,0,1,''));
  my $r_cmdAttribs=$commandTypes{$commandCode};
  if(! defined $r_cmdAttribs) {
    $sl->log("Unable to unmarshall command, unknown command code \"$commandCode\"",1);
    return [];
  }
  my ($commandName,$minParamSize,$paramSize,$paramTemplate,$utf8ParamIdx,$msgSizeMode)=
      @{$r_cmdAttribs}{qw'name minParamSize paramSize paramTemplate utf8ParamIdx msgSizeMode'};

  my $paramLength=length($marshalled);
  if(defined $minParamSize && $paramLength < $minParamSize) {
    $sl->log("Unable to unmarshall $commandName command (incomplete command)",1);
    return [];
  }
  if(defined $paramSize) {
    if($paramLength < $paramSize) {
      $sl->log("Unable to unmarshall $commandName command (incomplete command)",1);
      return [];
    }
    $sl->log("Superfluous data in $commandName command parameter (expected size: $paramSize, actual size: $paramLength)",2)
        if($paramLength > $paramSize);
  }

  my @cmdParams;
  if(defined $paramTemplate) {
    @cmdParams=unpack($paramTemplate,$marshalled);
  }elsif(defined $utf8ParamIdx) {
    @cmdParams=($marshalled);
  }

  if($commandName eq 'SERVER_GAMEOVER') {
    my ($msgSize,$playerNum,@winningAllyTeams)=@cmdParams;
    @cmdParams=($msgSize,$playerNum,\@winningAllyTeams);
  }elsif($commandName eq 'GAME_LUAMSG') {
    my $netMsgType=shift(@cmdParams);
    if($netMsgType != NETMSG_LUAMSG) {
      $sl->log("Invalid GAME_LUAMSG command, wrong network message type (expected NETMSG_LUAMSG=".NETMSG_LUAMSG.", got $netMsgType)",1);
      return [];
    }
  }

  if(defined $msgSizeMode) {
    my $msgSize=shift(@cmdParams);
    my $expectedSize=$paramLength+$msgSizeMode;
    if($msgSize != $expectedSize) {
      $sl->log("Invalid $commandName command, provided message size ($msgSize) does NOT match actual message size ($expectedSize)",1);
      return [];
    }
  }

  $cmdParams[$utf8ParamIdx]=decode('utf-8',$cmdParams[$utf8ParamIdx])
      if(defined $utf8ParamIdx && defined $cmdParams[$utf8ParamIdx]);

  unshift(@cmdParams,$commandName);
  return \@cmdParams;
}

# Business functions ##########################################################

sub addCallbacks {
  my ($self,$p_callbacks,$nbCalls,$priority)=@_;
  $priority=caller() unless(defined $priority);
  $nbCalls=0 unless(defined $nbCalls);
  my %callbacks=%{$p_callbacks};
  foreach my $command (keys %callbacks) {
    $self->{callbacks}{$command}={} unless(exists $self->{callbacks}{$command});
    if(exists $self->{callbacks}{$command}{$priority}) {
      $self->{conf}{simpleLog}->log("Replacing an existing $command callback for priority \"$priority\"",2);
    }
    $self->{callbacks}{$command}{$priority}=[$callbacks{$command},$nbCalls];
  }
}

sub removeCallbacks {
  my ($self,$p_commands,$priority)=@_;
  $priority=caller() unless(defined $priority);
  my @commands=@{$p_commands};
  foreach my $command (@commands) {
    if(exists $self->{callbacks}{$command}) {
      delete $self->{callbacks}{$command}{$priority};
      delete $self->{callbacks}{$command} unless(%{$self->{callbacks}{$command}});
    }
  }
}

sub addPreCallbacks {
  my ($self,$p_preCallbacks,$priority)=@_;
  $priority=caller() unless(defined $priority);
  foreach my $command (keys %{$p_preCallbacks}) {
    $self->{preCallbacks}{$command}={} unless(exists $self->{preCallbacks}{$command});
    if(exists $self->{preCallbacks}{$command}{$priority}) {
      $self->{conf}{simpleLog}->log("Replacing an existing $command pre-callback for priority \"$priority\"",2);
    }
    $self->{preCallbacks}{$command}{$priority}=$p_preCallbacks->{$command};
  }
}

sub removePreCallbacks {
  my ($self,$p_commands,$priority)=@_;
  $priority=caller() unless(defined $priority);
  foreach my $command (@{$p_commands}) {
    if(exists $self->{preCallbacks}{$command}) {
      delete $self->{preCallbacks}{$command}{$priority};
      delete $self->{preCallbacks}{$command} unless(%{$self->{preCallbacks}{$command}});
    }
  }
}

sub open {
  my $self = shift;
  my %conf=%{$self->{conf}};
  my $sl=$conf{simpleLog};
  $sl->log("Listening on AutoHost port (127.0.0.1:$conf{autoHostPort})",3);
  if((defined $self->{autoHostSock}) && $self->{autoHostSock}) {
    $sl->log("Could not start listening on AutoHost port (already listening)!",2);
    return $self->{autoHostSock};
  }
  $self->{autoHostSock} = new IO::Socket::INET(LocalHost => "127.0.0.1",
                                               LocalPort => $conf{autoHostPort},
                                               Proto => 'udp',
                                               Blocking => 0);
  if(! $self->{autoHostSock}) {
    $sl->log("Unable to listen on 127.0.0.1:$conf{autoHostPort} ($@)",0);
    undef $self->{autoHostSock};
    return 0;
  }
  return $self->{autoHostSock};
}

sub close {
  my $self = shift;
  my %conf=%{$self->{conf}};
  my $sl=$conf{simpleLog};
  $sl->log("Closing AutoHost interface",3);
  if(! ((defined $self->{autoHostSock}) && $self->{autoHostSock})) {
    $sl->log("Unable to close AutoHost interface (already closed)!",2);
  }else{
    close($self->{autoHostSock});
    undef $self->{autoHostSock};
  }
  $self->{state}=SRV_STATE_NOT_RUNNING;
  $self->{players}={};
  $self->{gameId}='';
  $self->{demoName}='';
}

sub sendChatMessage {
  my ($self,$message) = @_;
  my %conf=%{$self->{conf}};
  my $sl=$conf{simpleLog};
  if(! ((defined $self->{autoHostSock}) && $self->{autoHostSock})) {
    $sl->log("Unable to send chat message (AutoHost interface not opened)",1);
    return 0;
  }
  if(! $self->{state}) {
    $sl->log("Unable to send chat message (server not connected)",1);
    return 0;
  }
  my $autoHostSock=$self->{autoHostSock};
  $autoHostSock->send(encode('utf-8',$message));
  $sl->log("Sent on AutoHost interface: \"$message\"",5);
  if($message =~ /^\/([^ ]+)(?: +(.+))?$/) {
    my ($cmd,$param)=(uc($1),$2);
    if(exists($self->{callbacks}{"HOOK_$cmd"})) {
      foreach my $prio (sort prioSort (keys %{$self->{callbacks}{"HOOK_$cmd"}})) {
        my ($callback,$nbCalls)=@{$self->{callbacks}{"HOOK_$cmd"}{$prio}};
        if($nbCalls == 1) {
          delete $self->{callbacks}{"HOOK_$cmd"}{$prio};
        }elsif($nbCalls > 1) {
          $nbCalls-=1;
          $self->{callbacks}{"HOOK_$cmd"}{$prio}=[$callback,$nbCalls];
        }
        &{$callback}($cmd,$param) if($callback);
      }
      delete $self->{callbacks}{"HOOK_$cmd"} unless(%{$self->{callbacks}{"HOOK_$cmd"}});
    }
  }
  return 1;
}

sub prioSort {
  if($a =~ /^\d+$/ && $b =~ /^\d+$/) {
    return $a <=> $b;
  }
  if($a =~ /^\d+$/) {
    return $a <=> 1000;
  }
  if($b =~ /^\d+$/) {
    return 1000 <=> $b;
  }
  return 0;
}

sub receiveCommand {
  my $self=shift;
  my %conf=%{$self->{conf}};
  my $sl=$conf{simpleLog};
  if(! ((defined $self->{autoHostSock}) && $self->{autoHostSock})) {
    $sl->log("Unable to receive command (AutoHost interface not opened)",1);
    return 0;
  }
  my $autoHostSock=$self->{autoHostSock};
  my $recvBuf;
  $autoHostSock->recv($recvBuf,MTU_LOCALHOST);
  if(! defined $recvBuf) {
    $sl->log("Error while receiving message on AutoHost interface: $!",2);
    return 0;
  }
  if($recvBuf eq '') {
    $sl->log('Empty message received on AutoHost interface',2);
    return 0;
  }
  {
    no warnings 'utf8';
    $sl->log("Received from game server: \"$recvBuf\"",5);
  }
  my $p_command=$self->unmarshallCommand($recvBuf);
  return 0 unless(@{$p_command});
  $sl->log(" --> unmarshalled as:\"".join(",",map {paramToString($_)} @{$p_command})."\"",5);

  my $commandName=$p_command->[0];
  my $processed=0;

  if(exists($self->{preCallbacks}{'_ALL_'})) {
    foreach my $prio (sort prioSort (keys %{$self->{preCallbacks}{'_ALL_'}})) {
      $processed=1;
      my $p_preCallback=$self->{preCallbacks}{'_ALL_'}{$prio};
      &{$p_preCallback}(@{$p_command}) if($p_preCallback);
    }
  }
  if(exists($self->{preCallbacks}{$commandName})) {
    foreach my $prio (sort prioSort (keys %{$self->{preCallbacks}{$commandName}})) {
      $processed=1;
      my $p_preCallback=$self->{preCallbacks}{$commandName}{$prio};
      &{$p_preCallback}(@{$p_command}) if($p_preCallback);
    }
  }

  my $rc=1;
  if(exists($commandHandlers{$commandName})) {
    $processed=1;
    $rc = &{$commandHandlers{$commandName}}($self,@{$p_command}) if($commandHandlers{$commandName});
  }

  if(exists($self->{callbacks}{$commandName})) {
    foreach my $prio (sort prioSort (keys %{$self->{callbacks}{$commandName}})) {
      my ($callback,$nbCalls)=@{$self->{callbacks}{$commandName}{$prio}};
      $processed=1;
      if($nbCalls == 1) {
        delete $self->{callbacks}{$commandName}{$prio};
      }elsif($nbCalls > 1) {
        $nbCalls-=1;
        $self->{callbacks}{$commandName}{$prio}=[$callback,$nbCalls];
      }
      $rc = &{$callback}(@{$p_command}) && $rc if($callback);
    }
    delete $self->{callbacks}{$commandName} unless(%{$self->{callbacks}{$commandName}});
  }

  if(! $processed && $conf{warnForUnhandledMessages}) {
    {
      no warnings 'utf8';
      $sl->log("Unexpected/unhandled command received: \"$recvBuf\"",2);
    }
    $rc=0;
  }

  return $rc;
};

sub checkGameOver {
  my $self=shift;
  my ($nbOver,$nbInProgress)=(0,0);
  foreach my $playerNb (keys %{$self->{players}}) {
    if(defined $self->{players}{$playerNb}{winningAllyTeams}) {
      $nbOver++;
    }elsif($self->{players}{$playerNb}{disconnectCause} < CLI_STATE_CONNECTION_LOST) {
      $nbInProgress++;
    }
  }
  $self->{state}=SRV_STATE_GAME_OVER if($nbOver > $nbInProgress);
}

# Internal handlers ###########################################################

sub serverStartedHandler {
  my $self=shift;
  $self->{state}=SRV_STATE_SERVER_STARTED;
  $self->{gameId}='';
  $self->{demoName}='';
  return 1;
}

sub serverQuitHandler {
  my $self=shift;
  $self->{state}=SRV_STATE_NOT_RUNNING;
  $self->{players}={};
  return 1;
}

sub serverStartPlayingHandler {
  my ($self,undef,$gameId,$demoName)=@_;
  $self->{state}=SRV_STATE_GAME_STARTED;
  $self->{gameId}=$gameId if(defined $gameId);
  $self->{demoName}=$demoName if(defined $demoName);
  return 1;
}

sub serverGameOverHandler {
  my ($self,undef,$playerNb,$r_winningAllyTeams)=@_;
  my %conf=%{$self->{conf}};
  my $sl=$conf{simpleLog};
  if(exists $self->{players}{$playerNb}) {
    $self->{players}{$playerNb}{winningAllyTeams}=$r_winningAllyTeams;
    $self->checkGameOver();
  }else{
    $sl->log("Ignoring SERVER_GAMEOVER message on AutoHost interface (unknown player number $playerNb)",1);
  }
  return 1;
}

sub serverMessageHandler {
  my ($self,undef,$msg)=@_;
  my %conf=%{$self->{conf}};
  my $sl=$conf{simpleLog};
  if($msg =~ /^Connection attempt from ([^\ ]+)$/) {
    $self->{connectingPlayer}{name}=$1;
    $self->{connectingPlayer}{version}='';
    $self->{connectingPlayer}{address}='';
  }elsif($msg =~ /^ -> Version: (.*)$/) {
    $self->{connectingPlayer}{version}=$1;
  }elsif($msg =~ /^ -> Address: (.*)$/) {
    $self->{connectingPlayer}{address}=$1;
  }elsif($msg =~ /^ -> Connection established \(given id (\d+)\)$/) {
    my $playerNb=$1;
    if(exists $self->{players}{$playerNb}) {
      if($self->{players}{$playerNb}{name} eq '~'.$self->{connectingPlayer}{name}) {
        $self->{connectingPlayer}{name}='~'.$self->{connectingPlayer}{name};
      }
      if($self->{connectingPlayer}{name} ne $self->{players}{$playerNb}{name}) {
        $sl->log("Received a SERVER_MESSAGE command saying player \#$playerNb was $self->{connectingPlayer}{name}, whereas PLAYER_JOINED said it was $self->{players}{$playerNb}{name}",1);
      }else{
        $self->{players}{$playerNb}{version}=$self->{connectingPlayer}{version};
        $self->{players}{$playerNb}{address}=$self->{connectingPlayer}{address};
        $self->{players}{$playerNb}{disconnectCause}=CLI_STATE_LOADING;
      }
    }else{
      $self->{players}{$playerNb} = { name => $self->{connectingPlayer}{name},
                                      disconnectCause => CLI_STATE_LOADING,
                                      ready => RDY_STATE_NOT_PLACED,
                                      lost => 0,
                                      version => $self->{connectingPlayer}{version},
                                      address => $self->{connectingPlayer}{address},
                                      winningAllyTeams => undef,
                                      playerNb => $playerNb };
    }
    $self->{connectingPlayer}{name}='';
    $self->{connectingPlayer}{version}='';
    $self->{connectingPlayer}{address}='';
  }
  return 1;
}

sub playerJoinedHandler {
  my ($self,undef,$playerNb,$name)=@_;
  my %conf=%{$self->{conf}};
  my $sl=$conf{simpleLog};
  if(exists $self->{players}{$playerNb}) {
    if($name eq '~'.$self->{players}{$playerNb}{name}) {
      $self->{players}{$playerNb}{name}='~'.$self->{players}{$playerNb}{name};
    }
    if($name ne $self->{players}{$playerNb}{name}) {
      $sl->log("Received a PLAYER_JOINED command saying player \#$playerNb was $name, whereas SERVER_MESSAGE said it was $self->{players}{$playerNb}{name}",1);
    }else{
      $self->{players}{$playerNb}{disconnectCause}=CLI_STATE_CONNECTED;
    }
  }else{
    $self->{players}{$playerNb} = { name => $name,
                                    disconnectCause => CLI_STATE_CONNECTED,
                                    ready => RDY_STATE_NOT_PLACED,
                                    lost => 0,
                                    version => '',
                                    address => '',
                                    winningAllyTeams => undef,
                                    playerNb => $playerNb };
  }
  return 1;
}

sub playerLeftHandler {
  my ($self,undef,$playerNb,$reason)=@_;
  my %conf=%{$self->{conf}};
  my $sl=$conf{simpleLog};
  if(exists $self->{players}{$playerNb}) {
    $self->{players}{$playerNb}{disconnectCause}=$reason;
    $self->checkGameOver();
  }else{
    $sl->log("Ignoring PLAYER_LEFT message on AutoHost interface (unknown player number $playerNb)",1);
  }
  return 1;
}

sub playerReadyHandler {
  my ($self,undef,$playerNb,$readyState)=@_;
  my %conf=%{$self->{conf}};
  my $sl=$conf{simpleLog};
  if(exists $self->{players}{$playerNb}) {
    $self->{players}{$playerNb}{ready}=$readyState;
  }else{
    $sl->log("Ignoring PLAYER_READY message on AutoHost interface (unknown player number $playerNb)",1);
  }
  return 1;
}

sub playerDefeatedHandler {
  my ($self,undef,$playerNb)=@_;
  my %conf=%{$self->{conf}};
  my $sl=$conf{simpleLog};
  if(exists $self->{players}{$playerNb}) {
    $self->{players}{$playerNb}{lost}=1;
  }else{
    $sl->log("Ignoring PLAYER_DEFEATED message on AutoHost interface (unknown player number $playerNb)",1);
  }
  return 1;
}

1;
