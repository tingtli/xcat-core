# IBM(c) 2007 EPL license http://www.eclipse.org/legal/epl-v10.html

package xCAT::PPC;
use strict;
use lib "/opt/xcat/lib/perl";
use xCAT::Table;
use xCAT::Utils;
use xCAT::Usage;
use POSIX "WNOHANG";
use Storable qw(freeze thaw);
use Time::HiRes qw(gettimeofday sleep);
use IO::Select;
use Socket;
use xCAT::PPCcli; 
use xCAT::GlobalDef;
use xCAT::DBobjUtils;
use xCAT_monitoring::monitorctrl;
use Thread qw(yield);

##########################################
# Globals
##########################################
my %modules = (
  rinv      => "xCAT::PPCinv",
  rpower    => "xCAT::PPCpower",
  rvitals   => "xCAT::PPCvitals",
  rscan     => "xCAT::PPCscan",
  mkvm      => "xCAT::PPCvm",
  rmvm      => "xCAT::PPCvm",
  lsvm      => "xCAT::PPCvm",
  chvm      => "xCAT::PPCvm",
  rnetboot  => "xCAT::PPCboot",
  getmacs   => "xCAT::PPCmac",
  reventlog => "xCAT::PPClog",
  rspconfig => "xCAT::PPCcfg",
  rflash => "xCAT::PPCrflash"
);

##########################################
# Database errors
##########################################
my %errmsg = (
  NODE_UNDEF =>"Node not defined in '%s' database",
  NO_ATTR    =>"'%s' not defined in '%s' database",  
  DB_UNDEF   =>"'%s' database not defined"
);


##########################################################################
# Invokes the callback with the specified message                    
##########################################################################
sub send_msg {

    my $request = shift;
    my $ecode   = shift;
    my %output;

    #################################################
    # Called from child process - send to parent
    #################################################
    if ( exists( $request->{pipe} )) {
        my $out = $request->{pipe};

        $output{errorcode} = $ecode;
        $output{data} = \@_;
        print $out freeze( [\%output] );
        print $out "\nENDOFFREEZE6sK4ci\n";
    }
    #################################################
    # Called from parent - invoke callback directly
    #################################################
    elsif ( exists( $request->{callback} )) {
        my $callback = $request->{callback};

        $output{errorcode} = $ecode;
        $output{data} = \@_;
        $callback->( \%output );
    }
}


##########################################################################
# Fork child to execute remote commands
##########################################################################
sub process_command {

    my $request  = shift;
    my %nodes    = ();
    my $callback = $request->{callback};
    my $sitetab  = xCAT::Table->new( 'site' );
    my @site     = qw(ppcmaxp ppctimeout maxssh ppcretry fsptimeout); 
    my $start;

    #######################################
    # Default site table attributes 
    #######################################
    $request->{ppcmaxp}    = 64;
    $request->{ppctimeout} = 0;
    $request->{fsptimeout} = 0;
    $request->{ppcretry}   = 3;
    $request->{maxssh}     = 10;

    #######################################
    # Get site table attributes 
    #######################################
    if ( defined( $sitetab )) {
        foreach ( @site ) {
            my ($ent) = $sitetab->getAttribs({ key=>$_},'value');
            if ( defined($ent) ) { 
                $request->{$_} = $ent->{value}; 
            }
        }
    }
    if ( exists( $request->{verbose} )) {
        $start = Time::HiRes::gettimeofday();
    }
    #######################################
    # Group nodes based on command
    #######################################
    my $nodes = preprocess_nodes( $request );
    if ( !defined( $nodes )) {
        return(1);
    }

  #get new node status
  my %nodestat=();
  my $check=0;
  my $newstat;
  if ($request->{command} eq 'rpower') {
    my $subcommand=$request->{arg}->[0];
    if (($subcommand ne 'stat') && ($subcommand ne 'status') && ($subcommand ne 'state')) { 
      $check=1;
      my $noderange = $request->{node}; 
      my @allnodes=@$noderange;

      if ($subcommand eq 'off') { $newstat=$::STATUS_POWERING_OFF; }
      else { $newstat=$::STATUS_BOOTING;}
      foreach (@allnodes) { $nodestat{$_}=$newstat; }

      if ($subcommand ne 'off') {
        #get the current nodeset stat
        if (@allnodes>0) {
   my $nsh={};
          my ($ret, $msg)=xCAT::Utils->getNodesetStates(\@allnodes, $nsh);
          if ($ret) { trace( $request, $msg );}
          else {
            foreach (keys %$nsh) {
       my $currstate=$nsh->{$_};
              $nodestat{$_}=xCAT_monitoring::monitorctrl->getNodeStatusFromNodesetState($currstate, "rpower");
     }
   }
        }
      }
    }
  } elsif ($request->{command} eq 'rnetboot') { 
    $check=1;
    my $noderange = $request->{node}; 
    my @allnodes=@$noderange;
    #get the current nodeset stat
    if (@allnodes>0) {
      my $nsh={};
      my ($ret, $msg)=xCAT::Utils->getNodesetStates(\@allnodes, $nsh);
      if ($ret) { trace( $request, $msg );}
      else {
        foreach (keys %$nsh) {
          my $currstate=$nsh->{$_};
          $nodestat{$_}=xCAT_monitoring::monitorctrl->getNodeStatusFromNodesetState($currstate, "netboot");
        }
      }
    }
  }


    #######################################
    # Fork process
    #######################################
    my $children = 0;
    $SIG{CHLD} = sub { while (waitpid(-1, WNOHANG) > 0) { $children--; } };
    my $fds = new IO::Select;
    my $hw;
    my $sessions;

   
    foreach ( @$nodes ) {
        while ( $children > $request->{ppcmaxp} ) {
            my $errornodes={};
            child_response( $callback, $fds, $errornodes);

            #update the node status to the nodelist.status table
            if ($check) {
         updateNodeStatus(\%nodestat, $errornodes);
            }

            Time::HiRes::sleep(0.1);
        }
        ###################################
        # sleep between connects to same
        # HMC/IVM so as not to overwelm it
        ###################################
        if ( $hw ne @$_[0] ) {
            $sessions = 1;
        } elsif ( $sessions++ >= $request->{maxssh} ) {
            sleep(1);
            $sessions = 1;
        }
        $hw = @$_[0];

        my $pipe = fork_cmd( @$_[0], @$_[1], $request );
        if ( $pipe ) {
            $fds->add( $pipe );
            $children++;
        }
    }
    #######################################
    # Process responses from children
    #######################################
    while ( $fds->count > 0 or $children > 0 ) {
        my $errornodes={};
        child_response( $callback, $fds, $errornodes);

        #update the node status to the nodelist.status table
        if ($check) {
   updateNodeStatus(\%nodestat, $errornodes);
        }

        Time::HiRes::sleep(0.1);
    }
    
    #drain one more time
    my $rc=1;
    while ( $rc>0 ) {
      my $errornodes={};
      $rc=child_response( $callback, $fds, $errornodes);
      #update the node status to the nodelist.status table
      if ($check) {
        updateNodeStatus(\%nodestat, $errornodes);
      }
    }

    if ( exists( $request->{verbose} )) {
        my $elapsed = Time::HiRes::gettimeofday() - $start;
        my $msg     = sprintf( "Total Elapsed Time: %.3f sec\n", $elapsed );
        trace( $request, $msg );
    }

    return(0);
}

##########################################################################
# updateNodeStatus
##########################################################################
sub updateNodeStatus {
  my $nodestat=shift;
  my $errornodes=shift;
  my %node_status=();
  foreach my $node (keys(%$errornodes)) {
    if ($errornodes->{$node} == -1) { next;} #has error, not updating status
    my $stat=$nodestat->{$node};
    if (exists($node_status{$stat})) {
      my $pa=$node_status{$stat};
      push(@$pa, $node);
    }
    else {
      $node_status{$stat}=[$node];
    }
  }
  xCAT_monitoring::monitorctrl::setNodeStatusAttributes(\%node_status, 1);
}

##########################################################################
# Verbose mode (-V)
##########################################################################
sub trace {

    my $request = shift;
    my $msg   = shift;

    my ($sec,$min,$hour,$mday,$mon,$yr,$wday,$yday,$dst) = localtime(time);
    my $formatted = sprintf "%02d:%02d:%02d %5d %s", $hour,$min,$sec,$$,$msg;

    my $callback = $request->{callback};
    $callback->( {data=>[$formatted]} );
}


##########################################################################
# Send response from child process back to xCAT client
##########################################################################
sub child_response {

    my $callback = shift;
    my $fds = shift;
    my $errornodes=shift;
    my @ready_fds = $fds->can_read(1);
    my $rc = @ready_fds;

    foreach my $rfh (@ready_fds) {
        my $data = <$rfh>;

        #################################
        # Read from child process
        #################################
        if ( defined( $data )) {
            while ($data !~ /ENDOFFREEZE6sK4ci/) {
                $data .= <$rfh>;
            }
            my $responses = thaw($data);
            foreach ( @$responses ) {
                #save the nodes that has errors for node status monitoring
                if ((exists($_->{errorcode})) && ($_->{errorcode} != 0))  { 
                   if ($errornodes) { $errornodes->{$_->{node}->[0]->{name}->[0]}=-1; } 
        } else {
                   if ($errornodes) { $errornodes->{$_->{node}->[0]->{name}->[0]}=1; } 
               }
                $callback->( $_ );
            }
            next;
        }
        #################################
        # Done - close handle
        #################################
        $fds->remove($rfh);
        close($rfh);
    }
    yield; #Try to avoid useless iterations as much as possible
    return $rc;
} 


##########################################################################
# Finds attributes for given node is various databases
##########################################################################
sub resolve_hcp {

    my $request   = shift;
    my $noderange = shift;
    my @nodegroup = ();
    my $tab       = ($request->{hwtype} eq "fsp") ? "ppcdirect" : "ppchcp";
    my $db        = xCAT::Table->new( $tab );

    ####################################
    # Database not defined 
    ####################################
    if ( !defined( $db )) {
        send_msg( $request, 1, sprintf( $errmsg{DB_UNDEF}, $tab ));
        return undef;
    }
    ####################################
    # Process each node
    ####################################
    foreach my $hcp ( @$noderange ) {
        my ($ent) = $db->getAttribs( {hcp=>$hcp},"hcp" );

        if ( !defined( $ent )) {
            my $msg = sprintf( "$hcp: $errmsg{NODE_UNDEF}", $tab );
            send_msg( $request, 1, $msg );
            next;
        }
        ################################
        # Get userid and password 
        ################################
        my @cred = xCAT::PPCdb::credentials( $hcp, $request->{hwtype} );
        $request->{$hcp}{cred} = \@cred;

        ################################
        # Save values
        ################################
        push @nodegroup,[$hcp];
    }
    return( \@nodegroup );

}


##########################################################################
# Group nodes depending on command
##########################################################################
sub preprocess_nodes {

    my $request   = shift;
    my $noderange = $request->{node};
    my $method    = $request->{method};
    my %nodehash  = ();
    my @nodegroup = ();
    my %tabs      = ();
    my $netwk;

    ########################################
    # Special cases
    #   rscan - Nodes are hardware control pts 
    #   Direct-attached FSP 
    ########################################
    if (( $request->{command} =~ /^(rscan|rspconfig)$/ ) or
        ( $request->{hwtype} eq "fsp" )) {
        my $result = resolve_hcp( $request, $noderange );
        return( $result );
    }
    ##########################################
    # Special processing - rnetboot 
    ##########################################
    if ( $request->{command} eq "rnetboot" ) { 
        $netwk = resolve_netwk( $request, $noderange );
        if ( !defined( %$netwk )) {
            return undef;
        }
    }
    ##########################################
    # Open databases needed
    ##########################################
    foreach ( qw(ppc vpd nodetype) ) {
        $tabs{$_} = xCAT::Table->new($_);

        if ( !exists( $tabs{$_} )) { 
            send_msg( $request, 1, sprintf( $errmsg{DB_UNDEF}, $_ )); 
            return undef;
        }
    }
    ##########################################
    # Group nodes
    ##########################################
    foreach my $node ( @$noderange ) {
        my $d = resolve( $request, $node, \%tabs );

        ######################################
        # Error locating node attributes
        ######################################
        if ( ref($d) ne 'ARRAY' ) {
            send_msg( $request, 1, "$node: $d");
            next;
        }
        ######################################
        # Get data values 
        ######################################
        my $hcp  = @$d[3];
        my $mtms = @$d[2];

        $nodehash{$hcp}{$mtms}{$node} = $d;
    } 
    ##########################################
    # Get userid and password
    ##########################################
    while (my ($hcp,$hash) = each(%nodehash) ) {   
        my @cred = xCAT::PPCdb::credentials( $hcp, $request->{hwtype} );
        $request->{$hcp}{cred} = \@cred;
    } 
    ##########################################
    # Group the nodes - we will fork one 
    # process per nodegroup array element. 
    ##########################################

    ##########################################
    # These commands are grouped on an
    # LPAR-by-LPAR basis - fork one process
    # per LPAR.  
    ##########################################
    if ( $method =~ /^(getmacs|rnetboot)$/ ) {
        while (my ($hcp,$hash) = each(%nodehash) ) {    
            while (my ($mtms,$h) = each(%$hash) ) {
                while (my ($lpar,$d) = each(%$h)) {
                    push @$d, $lpar;

                    ##########################
                    # Save network info
                    ##########################
                    if ( $method =~ /^rnetboot$/ ) {
                        push @$d, $netwk->{$lpar}; 
                    }
                    push @nodegroup,[$hcp,$d]; 
                }
            }
        }
        return( \@nodegroup );
    }
    ##########################################
    # Power control commands are grouped 
    # by CEC which is the smallest entity 
    # that commands can be sent to in parallel.  
    # If commands are sent in parallel to a
    # single CEC, the CEC itself will serialize 
    # them - fork one process per CEC.
    ##########################################
    elsif ( $method =~ /^powercmd/ ) {
        while (my ($hcp,$hash) = each(%nodehash) ) {    
            while (my ($mtms,$h) = each(%$hash) ) {    
                push @nodegroup,[$hcp,$h]; 
            }
        }
        return( \@nodegroup );
    }
    ##########################################
    # All other commands are grouped by
    # hardware control point - fork one
    # process per hardware control point.
    ##########################################
    while (my ($hcp,$hash) = each(%nodehash) ) {    
        push @nodegroup,[$hcp,$hash]; 
    }
    return( \@nodegroup );
}


##########################################################################
# Finds attributes for given node is various databases 
##########################################################################
sub resolve_netwk {

    my $request   = shift;
    my $noderange = shift;
    my %nethash   = xCAT::DBobjUtils->getNetwkInfo( $noderange );
    my $tab       = xCAT::Table->new( 'mac' );
    my %result    = ();
    my $ip;

    #####################################
    # Network attributes undefined 
    #####################################
    if ( !%nethash ) {
        send_msg( $request,1,sprintf( $errmsg{NODE_UNDEF}, "networks" ));
        return undef;
    }
    #####################################
    # mac database undefined
    #####################################
    if ( !defined( $tab )) {
        send_msg( $request, 1, sprintf( $errmsg{DB_UNDEF}, "mac" ));
        return undef;
    }

    foreach ( @$noderange ) {
        #################################
        # Get gateway (-G)
        #################################
        if ( !exists( $nethash{$_} )) {
            my $msg = sprintf( "$_: $errmsg{NODE_UNDEF}", "networks");
            send_msg( $request, 1, $msg );
            next;
        }
        my $gateway = $nethash{$_}{gateway};
        if ( !defined( $gateway )) {
            my $msg = sprintf("$_: $errmsg{NO_ATTR}","gateway","networks");
            send_msg( $request, 1, $msg );
            next;
        }
        $ip = xCAT::Utils::toIP( $gateway );
        if ( @$ip[0] != 0 ) {
            send_msg( $request, 1, "$_: Cannot resolve '$gateway'" );
            next;  
        }
        my $gateway_ip = @$ip[1];

        #################################
        # Get server (-S)
        #################################
        my $server = xCAT::Utils->GetMasterNodeName( $_ );
        if ( $server == 1 ) {
            send_msg( $request, 1, "$_: Unable to identify master" );
            next;
        }
        $ip = xCAT::Utils::toIP( $server );
        if ( @$ip[0] != 0 ) {
            send_msg( $request, 1, "$_: Cannot resolve '$server'" );
            next;  
        }
        my $server_ip = @$ip[1];

        #################################
        # Get client (-C)
        #################################
        $ip = xCAT::Utils::toIP( $_ ); 
        if ( @$ip[0] != 0 ) {
            send_msg( $request, 1, "$_: Cannot resolve '$_'" );
            next;  
        }
        my $client_ip = @$ip[1];
 
        #################################
        # Get mac-address (-m)
        #################################
        my ($ent) = $tab->getNodeAttribs( $_, ['mac'] );
        if ( !defined($ent) ) {
            my $msg = sprintf( "$_: $errmsg{NO_ATTR}","mac","mac");
            send_msg( $request, 1, $msg );
            next;
        }
        #################################
        # Save results 
        #################################
        $result{$_}{gateway} = $gateway_ip;
        $result{$_}{server}  = $server_ip;
        $result{$_}{client}  = $client_ip;
        $result{$_}{mac}     = $ent->{mac};
    }
    return( \%result );
}


##########################################################################
# Finds attributes for given node is various databases 
##########################################################################
sub resolve {

    my $request = shift;
    my $node    = shift;
    my $tabs    = shift;
    my @attribs = qw(id pprofile parent hcp);
    my @values  = ();

    #################################
    # Get node type 
    #################################
    my $ent = $tabs->{nodetype}->getNodeAttribs($node,[qw(nodetype node)]);
    if ( !defined( $ent )) {
        return( sprintf( $errmsg{NODE_UNDEF}, "nodetype" ));
    }
    #################################
    # Check for type
    #################################
    if ( !exists( $ent->{nodetype} )) {
        return( sprintf( $errmsg{NO_ATTR}, "nodetype","nodetype" ));
    }
    #################################
    # Check for valid "type"
    #################################
    my ($type) = grep( 
        /^$::NODETYPE_LPAR|$::NODETYPE_OSI|$::NODETYPE_BPA|$::NODETYPE_FSP$/, 
        split /,/, $ent->{nodetype} );

    if ( !defined( $type )) {
        return( "Invalid node type: $ent->{nodetype}" );
    }
    #################################
    # Get attributes 
    #################################
    my ($att) = $tabs->{ppc}->getNodeAttribs( $node, \@attribs );
 
    if ( !defined( $att )) { 
        return( sprintf( $errmsg{NODE_UNDEF}, "ppc" )); 
    }
    #################################
    # Special lpar processing 
    #################################
    if ( $type =~ /^$::NODETYPE_OSI|$::NODETYPE_LPAR$/ ) {
        $att->{bpa}  = 0;
        $att->{type} = "lpar";
        $att->{node} = $att->{parent};

        if ( !exists( $att->{parent} )) {
            return( sprintf( $errmsg{NO_ATTR}, "parent", "ppc" )); 
        }
        #############################
        # Get BPA (if any)
        #############################
        if (( $request->{command} eq "rvitals" ) &&
            ( $request->{method}  =~ /^all|temp$/ )) { 
           my ($ent) = $tabs->{ppc}->getNodeAttribs( $att->{parent},['parent']);
     
           #############################
           # Find MTMS in vpd database 
           #############################
           if (( defined( $ent )) && exists( $ent->{parent} )) {
               my @attrs = qw(mtm serial);
               my ($vpd) = $tabs->{vpd}->getAttribs($ent->{parent},\@attrs);

               if ( !defined( $vpd )) {
                   return( sprintf( $errmsg{NO_UNDEF}, "vpd" )); 
                }
                ########################
                # Verify attributes
                ########################
                foreach ( @attrs ) {
                    if ( !exists( $vpd->{$_} )) {
                        return( sprintf( $errmsg{NO_ATTR}, $_, "vpd" ));
                    }
                }
                $att->{bpa} = "$vpd->{mtm}*$vpd->{serial}";
            }
        }
    }
    #################################
    # Optional and N/A fields 
    #################################
    elsif ( $type =~ /^$::NODETYPE_FSP$/ ) {
        $att->{pprofile} = 0;
        $att->{id}       = 0;
        $att->{fsp}      = 0;
        $att->{node}     = $node;
        $att->{type}     = $type;
        $att->{parent}   = exists($att->{parent}) ? $att->{parent} : 0;
        $att->{bpa}      = $att->{parent};
    }
    elsif ( $type =~ /^$::NODETYPE_BPA$/ ) {
        $att->{pprofile} = 0;
        $att->{id}       = 0;
        $att->{bpa}      = 0;
        $att->{parent}   = 0;
        $att->{fsp}      = 0;
        $att->{node}     = $node;
        $att->{type}     = $type;
    }
    #################################
    # Find MTMS in vpd database 
    #################################
    my @attrs = qw(mtm serial);
    my ($vpd) = $tabs->{vpd}->getNodeAttribs($att->{node}, \@attrs );

    if ( !defined( $vpd )) {
        return( sprintf( $errmsg{NODE_UNDEF}, "vpd: ($att->{node})" )); 
    }
    ################################
    # Verify both vpd attributes
    ################################
    foreach ( @attrs ) {
        if ( !exists( $vpd->{$_} )) {
            return( sprintf( $errmsg{NO_ATTR}, $_, "vpd: ($att->{node})" ));
        }
    }
    $att->{fsp} = "$vpd->{mtm}*$vpd->{serial}";

    #################################
    # Verify required attributes
    #################################
    foreach my $at ( @attribs ) {
        if ( !exists( $att->{$at} )) {
            return( sprintf( $errmsg{NO_ATTR}, $at, "ppc" ));
        } 
    }
    #################################
    # Build array of data 
    #################################
    foreach ( qw(id pprofile fsp hcp type bpa) ) {
        push @values, $att->{$_};
    }
    return( \@values );
}



##########################################################################
# Forks a process to run the ssh command
##########################################################################
sub fork_cmd {

    my $host    = shift;
    my $nodes   = shift;
    my $request = shift;

    #######################################
    # Pipe childs output back to parent
    #######################################
    my $parent;
    my $child;
    pipe $parent, $child;
    my $pid = xCAT::Utils->xfork;

    if ( !defined($pid) ) {
        ###################################
        # Fork error
        ###################################
        send_msg( $request, 1, "Fork error: $!" );
        return undef;
    }
    elsif ( $pid == 0 ) {
        ###################################
        # Child process
        ###################################
        close( $parent );
        $request->{pipe} = $child;

        invoke_cmd( $host, $nodes, $request );
        exit(0);
    }
    else {
        ###################################
        # Parent process
        ###################################
        close( $child );
        return( $parent );
    }
    return(0);
}


##########################################################################
# Run the command, process the response, and send to parent
##########################################################################
sub invoke_cmd {

    my $host    = shift;
    my $nodes   = shift;
    my $request = shift;
    my $hwtype  = $request->{hwtype};
    my $verbose = $request->{verbose};
    my @exp;
    my $verbose_log;
    my @outhash;

    ########################################
    # Direct-attached FSP handler 
    ########################################
    if ( $hwtype eq "fsp" ) {
  
        ####################################
        # Dynamically load FSP module
        ####################################
        eval { require xCAT::PPCfsp };
        if ( $@ ) {
            send_msg( $request, 1, $@ );
            return;
        }
        my @exp = xCAT::PPCfsp::connect( $request, $host );

        ####################################
        # Error connecting 
        ####################################
        if ( ref($exp[0]) ne "LWP::UserAgent" ) {
            send_msg( $request, 1, $exp[0] );
            return;
        }
        my $result = xCAT::PPCfsp::handler( $host, $request, \@exp );

        ####################################
        # Output verbose Perl::LWP 
        ####################################
        if ( $verbose ) {
            $verbose_log = $exp[3];

            my %output;
            $output{data} = [$$verbose_log];
            unshift @$result, \%output;
        }
        my $out = $request->{pipe};
        print $out freeze( $result );
        print $out "\nENDOFFREEZE6sK4ci\n";
        return;
    }

    ########################################
    # HMC and IVM-managed handler
    # Connect to list of remote servers
    ########################################
    foreach ( split /,/, $host ) {
        @exp = xCAT::PPCcli::connect( $request, $hwtype, $_ );

        ####################################
        # Successfully connected 
        ####################################
        if ( ref($exp[0]) eq "Expect" ) {
            last;
        }
    }
    ########################################
    # Error connecting 
    ########################################
    if ( ref($exp[0]) ne "Expect" ) {
        send_msg( $request, 1, $exp[0] );
        return;
    }
    ########################################
    # Process specific command 
    ########################################
    my $result = runcmd( $request, $nodes, \@exp );

    ########################################
    # Close connection to remote server
    ########################################
    xCAT::PPCcli::disconnect( \@exp );

    ########################################
    # Get verbose Expect output
    ########################################
    if ( $verbose ) {
        $verbose_log = $exp[6];
    }
    ########################################
    # Return error
    ######################################## 
    if ( ref($result) ne 'ARRAY' ) {
        send_msg( $request, 1, $$verbose_log.$result );
        return;
    }
    ########################################
    # Prepend verbose output 
    ########################################
    if ( defined( $verbose_log )) {
        my %output;
        $output{data} = [$$verbose_log];
        push @outhash, \%output;
    }
    ########################################
    # Send result back to parent process
    ########################################
    if ( @$result[0] eq "FORMATDATA6sK4ci" ) {
        my $out = $request->{pipe};

        push @outhash, @$result[1];
        print $out freeze( [@outhash] );
        print $out "\nENDOFFREEZE6sK4ci\n";
        return;
    }
    ########################################
    # Format and send back to parent
    ########################################
    foreach ( @$result ) {
        my %output;
        $output{node}->[0]->{name}->[0] = @$_[0];
        $output{node}->[0]->{data}->[0]->{contents}->[0] = @$_[1];
        $output{errorcode} = @$_[2];
        push @outhash, \%output;
    }
    my $out = $request->{pipe};
    print $out freeze( [@outhash] );
    print $out "\nENDOFFREEZE6sK4ci\n";
}


##########################################################################
# Run the command method specified
##########################################################################
sub runcmd {

    my $request = shift;
    my $cmd     = $request->{command};
    my $method  = $request->{method};
    my $hwtype  = $request->{hwtype};
    my $modname = $modules{$cmd};

    ######################################
    # Command not supported
    ######################################
    if ( !defined( $modname )) {
        return( ["$cmd not a supported command by $hwtype method"] );
    }   
    ######################################
    # Load specific module
    ######################################
    eval "require $modname";
    if ( $@ ) {
        return( [$@] );
    }
    ######################################
    # Invoke method 
    ######################################
    no strict 'refs';
    my $result = ${$modname."::"}{$method}->($request,@_);
    use strict;

    return( $result );

}

##########################################################################
# Pre-process request from xCat daemon. Send the request to the the service
# nodes of the HCPs.
##########################################################################
sub preprocess_request {

  my $package  = shift;
  my $req      = shift;
  if ($req->{_xcatdest}) { return [$req]; }    #exit if preprocessed
  my $callback = shift;
  my @requests;

  ####################################
  # Get hwtype 
  ####################################
  $package =~ s/xCAT_plugin:://;

  ####################################
  # Prompt for usage if needed 
  ####################################
  my $noderange = $req->{node}; #Should be arrayref
  my $command = $req->{command}->[0];
  my $extrargs = $req->{arg};
  my @exargs=($req->{arg});
  if (ref($extrargs)) {
    @exargs=@$extrargs;
  }

  my $usage_string=xCAT::Usage->parseCommand($command, @exargs);
  if ($usage_string) {
    $callback->({data=>[$usage_string]});
    $req = {};
    return;
  }
  if (!$noderange) {
    $usage_string=xCAT::Usage->getUsage($command);
    $callback->({data=>[$usage_string]});
    $req = {};
    return;
  }   

  ##################################################################
  # get the HCPs for the LPARs in order to figure out which service 
  # nodes to send the requests to
  ###################################################################
  my $hcptab_name = ($package eq "fsp") ? "ppcdirect" : "ppchcp";
  my $hcptab  = xCAT::Table->new( $hcptab_name );
  unless ($hcptab ) {
    $callback->({data=>["Cannot open $hcptab_name table"]});
    $req = {};
    return;
  }
  # Check if each node is hcp 
  my %hcp_hash=();
  my @missednodes=();
  foreach ( @$noderange ) {
    my ($ent) = $hcptab->getAttribs( {hcp=>$_},"hcp" );
    if ( !defined( $ent )) {
      push @missednodes, $_;
      next;
    }
    push @{$hcp_hash{$_}{nodes}}, $_;
  }
  
  #check if the left-over nodes are lpars
  if (@missednodes > 0) {
    my $ppctab = xCAT::Table->new("ppc");
    unless ($ppctab) { 
      $callback->({data=>["Cannot open ppc table"]});
      $req = {};
      return;
    }
    foreach my $node (@missednodes) {
      my $ent=$ppctab->getNodeAttribs($node,['hcp']);
      if (defined($ent->{hcp})) { push @{$hcp_hash{$ent->{hcp}}{nodes}}, $node;}
      else { 
        $callback->({data=>["The node $node is neither a hcp nor an lpar"]});
        $req = {};
        return;
      }
    }
  }
 
  ####################
  #suport for "rflash", copy the rpm and xml packages from user-spcefied-directory to /install/packages_fw
  #####################	
 if ( $command eq "rflash" ) {
 	my $packages_fw = "/install/packages_fw";
	my $c = 0;
       	my $packages_d;
	foreach (@exargs) {
		$c++;
		if($_ eq "-p") {
			$packages_d = $exargs[$c];
			last;	
		}
	}
	if($packages_d ne $packages_fw ) {
		$exargs[$c] = $packages_fw;
		if(! -d $packages_d) {
              		$callback->({data=>["The directory $packages_d doesn't exist!"]});
	      		$req = ();
	       		return;
        	}
	
		#print "opening directory and reading names\n";
        	opendir DIRHANDLE, $packages_d;
        	my @dirlist= readdir DIRHANDLE;
       		closedir DIRHANDLE;

        	@dirlist = File::Spec->no_upwards( @dirlist );

        	# Make sure we have some files to process
        	#
        	if( !scalar( @dirlist ) ) {
              		$callback->({data=>["The directory $packages_d is empty !"]});
	      		$req = ();
	      		return;
        	}
	
		#Find the rpm lic file
        	my @rpmlist = grep /\.rpm$/, @dirlist;
		my @xmllist = grep /\.xml$/, @dirlist;
		if( @rpmlist == 0 | @xmllist == 0) {
              		$callback->({data=>["There isn't any rpm and xml files in the  directory $packages_d!"]});
	      		$req = ();
	      		return;
		}
	
		my $rpm_list =  join(" ", @rpmlist);
		my $xml_list = join(" ", @xmllist);
		 
		my $cmd;
		if( -d $packages_fw) {
             		$cmd = "rm -rf $packages_fw";
			xCAT::Utils->runcmd($cmd, 0);
	                if ($::RUNCMD_RC != 0)
        	        {
                	        $callback->({data=>["Failed to remove the old packages in $packages_fw."]});
                        	$req = ();
                      		 return;

                	}
        	}
	
		$cmd = "mkdir $packages_fw";
   		xCAT::Utils->runcmd("$cmd", 0);
		if ($::RUNCMD_RC != 0)
    		{
       		 	$callback->({data=>["$cmd failed."]});
	         	$req = ();
	         	return;

		}
	
		$cmd = "cp $packages_d/*.rpm  $packages_d/*.xml $packages_fw";
   		xCAT::Utils->runcmd($cmd, 0);
		if ($::RUNCMD_RC != 0)
    		{
       		 	$callback->({data=>["$cmd failed."]});
	         	$req = ();
	         	return;

		}

		$req->{arg} = \@exargs;
	}
  }
   
	
  # find service nodes for the HCPs
  # build an individual request for each service node
  my $service  = "xcat";
  my @hcps=keys(%hcp_hash);
  my $sn = xCAT::Utils->get_ServiceNode(\@hcps, $service, "MN");

  # build each request for each service node
  foreach my $snkey (keys %$sn)
  {
    #print "snkey=$snkey\n";
    my $reqcopy = {%$req};
    $reqcopy->{'_xcatdest'} = $snkey;
    my $hcps1=$sn->{$snkey};
    my @nodes=();
    foreach (@$hcps1) { 
      push @nodes, @{$hcp_hash{$_}{nodes}};
    }
    $reqcopy->{node} = \@nodes;
    #print "nodes=@nodes\n";
    push @requests, $reqcopy;
  }
  return \@requests;
}


##########################################################################
# Process request from xCat daemon
##########################################################################
sub process_request {

    my $package  = shift;
    my $req      = shift;
    my $callback = shift;

    ####################################
    # Get hwtype 
    ####################################
    $package =~ s/xCAT_plugin:://;

    ####################################
    # Build hash to pass around 
    ####################################
    my %request; 
    $request{command}  = $req->{command}->[0];
    $request{arg}      = $req->{arg};
    $request{node}     = $req->{node};
    $request{stdin}    = $req->{stdin}->[0]; 
    $request{hwtype}   = $package; 
    $request{callback} = $callback; 
    $request{method}   = "parse_args";

    ####################################
    # Process command-specific options
    ####################################
    my $opt = runcmd( \%request );

    ####################################
    # Return error
    ####################################
    if ( ref($opt) eq 'ARRAY' ) {
        send_msg( \%request, 1, @$opt );
        return(1);
    }
    ####################################
    # Option -V for verbose output
    ####################################
    if ( exists( $opt->{V} )) {
        $request{verbose} = 1;
    }
    ####################################
    # Process remote command
    ####################################
    $request{opt} = $opt; 
    process_command( \%request );
}

##########################################################################
# connect hmc via ssh and execute remote command
##########################################################################
sub sshcmds_on_hmc
{
    my $ip = shift;
    my $user = shift;
    my $password = shift;
    my @cmds = @_;
    
    my %handled;
    my @data;
    my @exp;
    for my $cmd (@cmds)
    {
        if ( $cmd =~ /(.+?)=(.*)/)
        {
            my ($command,$value) = ($1,$2);
            $handled{$command} = $value;
        }
    }
    my %request = (
            ppcretry => 1,
            verbose  => 0,
            ppcmaxp    => 64,
            ppctimeout => 0,
            fsptimeout => 0,
            ppcretry   => 3,
            maxssh     => 10

            );

    my $valid_ip;
    foreach my $individual_ip ( split /,/, $ip ) {
         ################################
         # Get userid and password 
         ################################
         my @cred = xCAT::PPCdb::credentials( $individual_ip, "hmc" );
         $request{$individual_ip}{cred} = \@cred;

        @exp = xCAT::PPCcli::connect( \%request, 'hmc', $individual_ip);
####################################
# Successfully connected 
####################################
        if ( ref($exp[0]) eq "Expect" ) {
            $valid_ip = $individual_ip;
            last;
        }
    }

########################################
# Error connecting 
########################################
    if ( ref($exp[0]) ne "Expect" ) {
        return ([1,@cmds]);
    }
########################################
# Process specific command 
########################################
    for my $cmd ( keys %handled)
    {
        my $result;
        if ($cmd eq 'network_reset')
        {
            $result = xCAT::PPCcli::network_reset( \@exp, $valid_ip, $handled{$cmd});
            my $RC = shift( @$result);
        }
        push @data, @$result[0]; 
    }
########################################
# Close connection to remote server
########################################
    xCAT::PPCcli::disconnect( \@exp );

    return ([0, undef, \@data]);
}

1;

