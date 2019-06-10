#!/usr/bin/env perl
use strict;
use warnings;

our $VERSION = '1.05';

# configuration. Adjust these to taste (boolean, unless noted)
my $root_dir              = '/var/db/sentry';
my $add_to_tcpwrappers    = 1;
my $add_to_pf             = 1;
my $add_to_ipfw           = 0;    # untested
my $add_to_iptables       = 0;    # untested
my $firewall_table        = 'sentry_blacklist';
my $expire_block_days     = 90;   # 0 to never expire
my $protect_ftp           = 1;
my $protect_smtp          = 0;
my $protect_mua           = 1;    # dovecot POP3 & IMAP
my $dl_url = 'https://raw.githubusercontent.com/msimerson/sentry/master/sentry.pl';

# perl modules from CPAN
my $has_netip = 0;
eval 'use Net::IP';  ## no critic
if ( !$@ ) {
    $has_netip = 1;
}
else {
    warn "Net::IP not installed. No IPv6 support.\n";
};

# perl built-in modules
BEGIN { @AnyDBM_File::ISA = qw(DB_File GDBM_File NDBM_File) }
use AnyDBM_File;
use Fcntl qw(:DEFAULT :flock LOCK_EX LOCK_NB);
use Data::Dumper;
use English qw( -no_match_vars );
use File::Copy;
use File::Path;
use Getopt::Long;
use Pod::Usage;

# parse command line options
Getopt::Long::GetOptions(
    'ip=s'      => \my $ip,
    'connect'   => \my $connect,
    'delist'    => \my $delist,
    'whitelist' => \my $whitelist,
    'blacklist' => \my $blacklist,
    'report'    => \my $report,
    'update'    => \my $self_update,
    'nfslock'   => \my $nfslock,  # TODO: document this
    'dbdump'    => \my $db_dump,
    'verbose'   => \my $verbose,
    'help'      => \my $help,
) or die "error parsing command line options\n";

my $tcpd_denylist = _get_denylist_file();  # where to put hosts.deny entries
my $latest_script = undef;
check_setup() or pod2usage( -verbose => 1);

my ($db_path,$db_lock,$db_tie,$db_key);
my %ip_record = ( seen => 0, white => 0, black => 0 );

_init_db();

# dispatch the request
if    ( $report    ) { do_report()    }
elsif ( $connect   ) { do_connect()   }
elsif ( $whitelist ) { do_whitelist() }
elsif ( $blacklist ) { do_blacklist() }
elsif ( $delist    ) { do_delist()    }
elsif ( $self_update ) { do_version_check(); upgrade_to_db(); }
elsif ( $help      ) { pod2usage( -verbose => 2) }
else                 { pod2usage( -verbose => 1) };

if ( $ip ) {
  $db_tie->{$db_key} = join('^', $ip_record{seen}, $ip_record{white}, $ip_record{black} );
};
upgrade_to_db();
untie $db_tie;
close $db_lock;
exit;

sub is_valid_ip {
    return unless $ip;
    eval 'use Net::IP';  ## no critic
    if ( ! $@ ) {
        new Net::IP ( $ip ) or die Net::IP::Error();
        print "ip $ip is valid\n" if $verbose;
        return $ip
    };

    if ( $ip =~ /^::ffff:/ ) {
# we have seen $ip in this IPv6 notation: ::ffff:208.75.177.98
        ($ip) = (split /:/, $ip)[-1]; # grab everything after the last :
    };

    my @octets = split /\./, $ip;
    return unless @octets == 4;                       # need 4 octets

    return if $octets[0] < 1;
    return if grep( $_ eq '255', @octets ) == 4;      # 255.255.255.255 invalid

    foreach (@octets) {
        return unless /^\d{1,3}$/ and $_ >= 0 and $_ <= 255;
        $_ = 0 + $_;
    }

    print "ip $ip is valid\n" if $verbose;
    return $ip
};

sub is_whitelisted {
    return if ! $ip_record{white};
    print "is whitelisted\n" if $verbose;
    return 1;
};

sub is_blacklisted {
    return if ! $ip_record{black};
    print "is blacklisted\n" if $verbose;
    return 1 if ! $expire_block_days;
    my $bl_ts = $ip_record{black};
    my $days_old = ( time() - $bl_ts ) / 3600 / 24;
    do_unblacklist() if $days_old > $expire_block_days;
    return 1;
};

sub check_setup {

    return 1 if $help;

    # check $root_dir is present
    if ( ! -d $root_dir ) {
        print "creating ssh sentry root at $root_dir\n";
        mkpath($root_dir, undef, oct('0750'))
            or die "unable to create $root_dir: $!\n";
    };

    configure_tcpwrappers();

    return 1 if ( $report || $self_update );

    return if ! is_valid_ip();

    print "setup checks succeeded\n" if $verbose;
    return 1;
};

sub configure_tcpwrappers {

    my $is_setup;
    foreach ( '/etc/hosts.allow', '/etc/hosts.deny', $tcpd_denylist ) {
        next if ! $_;
        next if ! -f $_ || ! -r $_;

        open my $FH, '<', $_;
        my @matches = grep { $_ =~ /sentry/ } <$FH>;
        close $FH;

        if ( scalar @matches > 0 ) {
            $is_setup++;
            last;
        };
    };

    return 1 if $is_setup;

    my $script_loc = _get_script_location();
    my $spawn = 'sshd : ALL : spawn ' . $script_loc . ' -c --ip=%a : allow';

    if ( $OSNAME =~ /freebsd|linux/ ) {
# FreeBSD & Linux have a modified tcpd, adding support for include files
        print "
NOTICE: you need to add these lines near the top of your /etc/hosts.allow file\n
sshd : $tcpd_denylist : deny
$spawn\n\n";
        return;
    }

    open my $FH, '>>', '/etc/hosts.deny'
        or warn "could not write to /etc/hosts.deny: $!" and return;
    print $FH "$spawn\n";
    close $FH;
};

sub install_myself {
    my $script_loc = _get_script_location();
    print "installing $0 to $script_loc\n" if $verbose;
    open FHW, '>', $script_loc or do {    ## no critic
        warn "unable to write to $script_loc: $!\n";
        return;
    };
    open my $fhr, '<', $0 or do {
        warn "unable to read $0: $!\n";
        close FHW;
        return;
    };
    print FHW '#!' . `which perl`;
    while (<$fhr>) { next if /^#!/; print FHW $_; }
    close $fhr;
    close FHW;
    chmod 0755, $script_loc;
    print "installed to $script_loc\n";
    return 1;
};

sub do_version_check {

    my $installed_ver = _get_installed_version() or do {
            install_myself() and return 1;
        };

    return if ! $self_update;

    my $release_ver   = _get_latest_release_version();
    my $this_ver      = $VERSION;

    if ( $installed_ver && $release_ver > $installed_ver ) {
        warn "you have sentry $installed_ver installed, version $release_ver is available\n";
    };
    if ( $installed_ver && $this_ver > $installed_ver ) {
        warn "you have sentry $installed_ver installed, version $release_ver is running\n";
    };

    if ($installed_ver >= $release_ver && $installed_ver >= $this_ver) {
        print "the latest version ($installed_ver) is installed\n";
        return;
    };

    install_myself() and return if $this_ver > $release_ver;
    install_from_web() if $release_ver > $this_ver;

    return 1;
};

sub install_from_web {
    return if ! $latest_script;
    my $script_loc = _get_script_location();

    print "installing latest sentry.pl to $script_loc\n";
    open FH, '>', $script_loc or die "error: $!\n"; ## no critic
    print FH '#!' . `which perl`;
    print FH $latest_script;
    close FH;
    chmod 0755, $script_loc;
    my ($latest_ver) = $latest_script =~ /VERSION\s*=\s*\'([0-9\.]+)\'/;
    print "upgraded $script_loc to $latest_ver\n";
    return 1;
};

sub do_connect {
    $ip_record{seen}++;

    return if is_whitelisted();
    return if is_blacklisted();
    return if $ip_record{seen} < 3;

    _parse_ssh_logs();
    _parse_ftp_logs()   if $protect_ftp;
    _parse_mail_logs()  if $protect_smtp || $protect_mua;
};

sub do_whitelist {
    print "whitelisting $ip\n" if $verbose;

    #printf( " called by %s, %s, %s\n", caller );
    $ip_record{white} = time;

    _allow_tcpwrappers() if $add_to_tcpwrappers;
    _allow_pf()          if $add_to_pf;
    _allow_ipfw()        if $add_to_ipfw;

    return 1;
};

sub do_blacklist {
    print "blacklisting $ip\n" if $verbose;

    $ip_record{black} = time;

    _block_tcpwrappers() if $add_to_tcpwrappers;
    _block_pf()          if $add_to_pf;
    _block_ipfw()        if $add_to_ipfw;

    return 1;
};

sub do_delist {
    do_unblacklist();
    do_unwhitelist();
};

sub do_unblacklist {
    print "unblacklisting $ip\n" if $verbose;
    $ip_record{black} = 0;

    _unblock_tcpwrappers() if $add_to_tcpwrappers;
    _unblock_pf()          if $add_to_pf;
    _unblock_ipfw()        if $add_to_ipfw;

    return;
};

sub do_unwhitelist {
    print "unwhitelisting $ip\n" if $verbose;
    $ip_record{white} = 0;
};

sub do_report {

    die "you cannot read $root_dir: $!\n" if ! -r $root_dir;

    upgrade_to_db();

    return if $ip && ! $verbose;

    my $unique_ips = keys %$db_tie;
    my %counts = ( seen => 0, white => 0, black => 0 );
    foreach my $key ( keys %$db_tie ) {
        my @vals = _parse_db_val( $db_tie->{ $key } );
        $counts{seen}  += $vals[0] || 0;
        $counts{white} ++ if $vals[1];
        $counts{black} ++ if $vals[2];
        print "$key: seen=$vals[0], w=$vals[1]\n" if $db_dump;
    };

    print "   -------- summary ---------\n";
    printf "%4.0f unique IPs have connected", $unique_ips;
    print " $counts{seen} times\n";
    printf "%4.0f IPs are whitelisted\n", $counts{white};
    printf "%4.0f IPs are blacklisted\n", $counts{black};
    print "\n";

    if ( $ip ) {
        _get_ssh_logs();
        _parse_ftp_logs() if $protect_ftp;
    };
};


sub _get_installed_version {
    my $script_loc = "$root_dir/sentry.pl";
    if ( ! -e $script_loc ) {
        warn "sentry not installed\n";
        return;
    };
    my ($ver) = `grep VERSION $script_loc` =~ /VERSION\s*=\s*\'([0-9\.]+)\'/ or do {
            warn "unable to determine installed version";
            return;
        };
    print "installed version is $ver\n" if $verbose;
    return $ver;
};

sub _get_url_lwp {
    eval 'require LWP::UserAgent'; ## no critic
    if ( $EVAL_ERROR ) {
        warn "LWP::UserAgent not installed\n";
        return;
    }

    my $ua = LWP::UserAgent->new( timeout => 4);
    my $response = $ua->get($dl_url);
    if (!$response->is_success) {
        warn $response->status_line;
        return;
    }

    return $response->decoded_content;
}

sub _get_url_cli {
    return `curl $dl_url || wget $dl_url || fetch -o - $dl_url`;
}

sub _get_latest_release_version {

    my $manual_msg = "try upgrading manually with:\n
curl -O /var/db/sentry/sentry.pl $dl_url
  or
fetch -o /var/db/sentry/sentry.pl $dl_url

chmod 755 /var/db/sentry/sentry.pl\n";

    my $doc = _get_url_lwp() || _get_url_cli();
    if (!$doc) {
        warn "unable to download latest script, $manual_msg";
        return 0;
    }

    my ($latest_ver) = $doc =~ /VERSION\s*=\s*\'([0-9\.]+)\'/;
    if ( ! $latest_ver ) {
        warn "could not determine latest version, $manual_msg\n";
        return 0;
    };
    print "most recent version: $latest_ver\n" if $verbose;
    return $latest_ver;
};

sub _get_script_location {
    return "$root_dir/sentry.pl";
};

sub _get_denylist_file {

# Linux and FreeBSD systems have custom versions of libwrap that permit
# storing IP lists in file referenced from hosts.allow or hosts.deny.
# On those systems, dump the blacklisted IPs into a special file

    return "$root_dir/hosts.deny" if $OSNAME =~ /linux|freebsd/i;
    return "/etc/hosts.deny";
};


sub _count_lines {
    my $path = shift;

    return 0 if ! -f $path;

    my $count;
    open my $FH, '<', $path;
    while ( <$FH> ) { $count++ };
    close $FH;
    return $count;
};

sub _allow_tcpwrappers {

    return if ! -e $tcpd_denylist;

    if ( ! -w $tcpd_denylist ) {
        warn "file $tcpd_denylist is not writable!\n";
        return;
    };

    my $err = "failed to delist from tcpwrappers\n";
    open my $TMP, '>', "$tcpd_denylist.tmp" or warn $err and return;
    open my $CUR, '<', $tcpd_denylist       or warn $err and return;
    while ( <$CUR> ) {
        next if $_ =~ / $ip /;  # discard the IP we want to whitelist
        print $TMP $_;
    };
    close $TMP;
    close $CUR;
    move( "$tcpd_denylist.tmp", $tcpd_denylist) or $err;
};

sub _allow_ipfw {

    my $ipfw = `which ipfw`;
    chomp $ipfw;
    if ( !$ipfw || ! -x $ipfw ) {
        warn "could not find ipfw!";
        return;
    };

    # TODO: look up the rule number and delete it
    my $rule_num = '';
    my $cmd = "delete $rule_num\n";
};

sub _allow_pf {

    my $pfctl = `which pfctl`;
    chomp $pfctl;
    if ( ! -x $pfctl ) {
        warn "could not find pfctl!";
        return;
    };

    # remove the IP from the PF table
    my $cmd = "-q -t $firewall_table -Tdelete $ip";
    system "$pfctl $cmd"
        and warn "failed to remove $ip from PF table $firewall_table";
};


sub _block_tcpwrappers {

    if ( -e $tcpd_denylist && ! -w $tcpd_denylist ) {
        warn "file $tcpd_denylist is not writable!\n";
        return;
    };

    my $error = "could not add $ip to blocklist: $!\n";

    # prepend the naughty IP to the hosts.deny file
    open(my $TMP, '>', "$tcpd_denylist.tmp") or warn $error and return;
### WARY: THAR BE DRAGONS HERE!
    print $TMP "ALL: $ip : deny\n";
# Linux and FreeBSD support an external filename referenced from
# /etc/hosts.[allow|deny]. However, that filename parsing is not
# identical to /etc/hosts.allow. Specifically, this works as
# expected in /etc/hosts.allow:
#    ALL : N.N.N.N : deny
# but it does not work in an external file! Be sure to use this syntax:
#    ALL: N.N.N.N : deny
# Lest thee find thyself wishing thou hadst
### /WARY

    # append the current hosts.deny to the temp file
    if ( -e $tcpd_denylist && -r $tcpd_denylist ) {
        open my $BL, '<', $tcpd_denylist or warn $error and return;
        while ( my $line = <$BL> ) {
            print $TMP $line;
        }
        close $BL;
    }
    close $TMP;

    # and finally install the new file
    move( "$tcpd_denylist.tmp", $tcpd_denylist );
};

sub _block_ipfw {

    my $ipfw = `which ipfw`;
    chomp $ipfw;
    if ( !$ipfw || ! -x $ipfw ) {
        warn "could not find ipfw!";
        return;
    };

# TODO: set this to a reasonable default
    my $cmd = "add deny all from $ip to any";
    warn "$ipfw $cmd\n";
    #system "$ipfw $cmd";  # TODO: this this
};

sub _block_pf {

    my $pfctl = `which pfctl`;
    chomp $pfctl;
    if ( ! -x $pfctl ) {
        warn "could not find pfctl!";
        return;
    };

    # add the IP to the chosen PF table
    my $args = "-q -t $firewall_table -T add $ip";
    #warn "$pfctl $args\n";
    system "$pfctl $args" and warn "failed to add $ip to PF table $firewall_table";

    #  kill all state entries for the blocked host
    system "$pfctl -q -k $ip";
};

sub _unblock_tcpwrappers {

    if ( ! -e $tcpd_denylist ) {
        warn "IP $ip not blocked in tcpwrappers\n";
        return;
    };

    if ( ! -w $tcpd_denylist ) {
        warn "file $tcpd_denylist is not writable!\n";
        return;
    };

    my $tmp = "$tcpd_denylist.tmp";
    if ( -e $tmp && ! -w $tmp ) {
        warn "file $tmp is not writable!\n";
        return;
    };

    my $error = "could not remove $ip from blocklist: $!\n";

    # open a temp file
    open(my $TMP, '>', $tmp) or warn $error and return;

    # cat the current hosts.deny to the temp file, omitting $ip
    open my $BL, '<', $tcpd_denylist or warn $error and return;
    while ( my $line = <$BL> ) {
        next if $line =~ /$ip/;
        print $TMP $line;
    }
    close $BL;
    close $TMP;

    # install the new file
    move( $tmp, $tcpd_denylist );
};

sub _unblock_ipfw {

    my $ipfw = `which ipfw`;
    chomp $ipfw;
    if ( !$ipfw || ! -x $ipfw ) {
        warn "could not find ipfw!";
        return;
    };

# TODO: test that this is reasonable
    my $cmd = "delete deny all from $ip to any";
    warn "$ipfw $cmd\n";
    #system "$ipfw $cmd";
};

sub _unblock_pf {

    my $pfctl = `which pfctl`;
    chomp $pfctl;
    if ( ! -x $pfctl ) {
        warn "could not find pfctl!";
        return;
    };

    # add the IP to the chosen PF table
    my $args = "-q -t $firewall_table -T delete $ip";
    #warn "$pfctl $args\n";
    system "$pfctl $args" and warn "failed to delete $ip from PF table $firewall_table";
    return 1;
};

sub _parse_ssh_logs {
    my $ssh_attempts = _get_ssh_logs();

# fail safely. If we can't parse the logs, skip the white/blacklist steps
    return if ! $ssh_attempts;

    if ( $ssh_attempts->{success} ) { do_whitelist(); return; };
    if ( $ssh_attempts->{naughty} ) { do_blacklist(); return; };

# do not use $seen_count here. If the ssh log parsing failed for any reason,
# legit users would not get whitelisted, and then after 10 attempts they
# would get backlisted.

    # no success or naughty, but > 10 connects, blacklist
    do_blacklist() if $ssh_attempts->{total} > 10;
};

sub _get_ssh_logs {

    my $logfile = _get_sshd_log_location();
    return if ! -f $logfile;
    print "checking for SSH logins in $logfile\n" if $verbose;

    my %count;
    open my $FH, '<', $logfile or warn "unable to read $logfile: $!\n" and return;
    while ( my $line = <$FH> ) {
        chomp $line;

        next if $line !~ / sshd/;
        next if $line !~ /$ip/;

# consider using Parse::Syslog if available
#
# WARNING: if you modify this, be mindful of log injection attacks.
# Anchor any regexps or otherwise exclude the user modifiable portions of the
# log entries when parsing

# Dec  3 12:14:16 pe   sshd[4026]: Accepted publickey for tnpimatt from 67.171.0.90 port 45189 ssh2
# Feb  8 20:49:21 spry sshd[1550]: Failed password for invalid user pentakill from 93.62.1.201 port 33210 ssh2

        my @bits = split /\s+/, $line;  # split on WS
        if    ( $bits[5] eq 'Accepted' ) { $count{success}++  }
        elsif ( $bits[5] eq 'Invalid'  ) { $count{naughty}++  }
        elsif ( $bits[5] eq 'Failed'   ) { $count{failed}++   }
        elsif ( $bits[5] eq 'Did'      ) { $count{probed}++   }
        elsif ( $bits[5] eq 'warning:' ) { $count{warnings}++ }
        # 113.160.203.24
        # PAM: authentication error for root from 113.160.203.24
        elsif ( $bits[5] eq '(pam_unix)' ) {
            $count{failed}++ and next if $line =~ /authentication failure; /;
            $count{naughty}++ and next if $line =~ /check pass; user unknown$/;
            print "pam_unix unknown: $line\n";
        }
        elsif ( $bits[5] eq 'error:' ) {
            $count{naughty}++ and next if $line =~ /exceeded for root/;
            if ( $bits[6] eq 'PAM:' ) {
# FreeBSD PAM authentication
                $count{naughty}++ and next if $line =~ /error for root/;
                $count{failed}++ and next if $line =~ /authentication error/;
                $count{naughty}++ and next if $line =~ /(invalid|illegal) user/;
            };
            $count{errors}++;
        }
        else {
#            if ( $line =~ /POSSIBLE BREAK-IN ATTEMPT!$/ ) {
# This only means their forward/reverse DNS isn't set up properly. Not a
# good criteria for blacklisting
#                $count{naughty}++;
#            };
#
#            if ( $line =~ /Did not receive identification string from/ ) {
# This entry means that something connected using the SSH protocol, but didn't
# attempt to authenticate. This could a SSH version probe, or a
# monitoring tool like Nagios or Hobbit.
#            };

            $count{unknown}++;
            print "unknown: $bits[5]: $line\n";
        }
    };
    close $FH;

    print Dumper(\%count) if $verbose;
    foreach ( qw/ success naughty errors failed probed warning unknown / ) {
        $count{total} += $count{$_} || 0;
    };

    return \%count;
};

sub _get_sshd_log_location {

# TODO
# a. check the date on the file, and make sure it is within the past month
# b. sample the file, and make sure its contents are what we expect

    # check the most common places
    my @log_files;
    push @log_files, 'auth.log';     # freebsd, debian
    push @log_files, 'secure';       # centos
    push @log_files, 'secure.log';   # darwin

    foreach ( @log_files ) {
        return "/var/log/$_" if -f "/var/log/$_";
    };

    # os specific locations (some are legacy)
    my $log;
    $log = '/var/log/system.log'      if $OSNAME =~ /darwin/i;
    $log = '/var/log/messages'        if $OSNAME =~ /freebsd/i;
    $log = '/var/log/messages'        if $OSNAME =~ /linux/i;
    $log = '/var/log/syslog'          if $OSNAME =~ /solaris/i;
    $log = '/var/adm/SYSLOG'          if $OSNAME =~ /irix/i;
    $log = '/var/adm/messages'        if $OSNAME =~ /aix/i;
    $log = '/var/log/messages'        if $OSNAME =~ /bsd/i;
    $log = '/usr/spool/mqueue/syslog' if $OSNAME =~ /hpux/i;

    return $log if -f $log;
    warn "unable to find your sshd logs.\n";

# TODO: check /etc/syslog.conf for location?
    return;
};

sub _parse_mail_logs {
    my $attempts = _get_mail_logs() or return;

    if ( $attempts->{success} ) { do_whitelist(); return; };
    if ( $attempts->{naughty} ) { do_blacklist(); return; };

    do_blacklist() if ($attempts->{total} && $attempts->{total} > 10);
};

sub _get_mail_logs {
# if you want to blacklist spamming IPs, you must alter this to support your
# MTA's log files.
# Note the comments in the _get_ssh_logs sub.
# I recommend returning a hashref like the one used in the ssh function.
# If parsing SpamAssassin logs, I'd set success to be anything virus free
#    and a spam score less than 5.
# Naughty might be more than 3 messages with spam scores above 10

    my $logfile = _get_mail_log_location();
    return if ! -f $logfile;
    print "checking for email logins in $logfile\n" if $verbose;

    open my $FH, '<', $logfile or do {
        warn "unable to read $logfile: $!\n";
        return;
    };

    my %count;
    while ( my $line = <$FH> ) {
        chomp $line;
        next if $line !~ /$ip/;  # ignore lines for other IPs

# Dec  3 05:42:59 pe dovecot: pop3-login: Aborted login (auth failed, 1 attempts): user=<www>, method=PLAIN, rip=37.46.80.95, lip=18.28.0.30
# Dec  3 05:43:06 pe dovecot: pop3-login: Disconnected (auth failed, 2 attempts): user=<info@***.edu>, method=PLAIN, rip=93.153.9.210, lip=18.28.0.30
# Dec  3 00:04:45 pe dovecot: imap-login: Login: user=<john@a**g***ar.com>, method=PLAIN, rip=127.0.0.24, lip=127.0.0.6, mpid=81292, session=<AnAB/AAAY>
# Dec  3 00:04:47 pe dovecot: imap-login: Login: user=<lyn@l*****er.com>, method=CRAM-MD5, rip=65.100.142.26, lip=127.0.0.6, mpid=81301, TLS, session=<4PFBZI4a>

        my ($mon, $day, $time, $host, $app, $proc, $msg) = split /\s+/, $line, 6;
        next if $msg !~ /$ip/;  # ignore lines for other IPs

        if  ( $app eq 'dovecot:' ) {
            if    ( $msg =~ '^Login:'         ) { $count{success}++ }
            elsif ( $msg =~ /auth failed/     ) { $count{naughty}++ }
            elsif ( $msg =~ /no auth attempt/ ) { $count{probed}++  }
            elsif ( $msg =~ /Disconnected/    ) { $count{info}++    }
            else  {
                print "unknown mail: $line\n";
                $count{unknown}++;
            };
        }
        elsif ( $proc eq 'vchkpw-smtp:' ) {
# Dec  5 07:56:27 pe vpopmail[1783]: vchkpw-smtp: null password given root:178.33.94.90
            if    ( $msg =~ /vpopmail user not found/ ) { $count{naughty}++ }
            elsif ( $msg =~ /null password/           ) { $count{naughty}++ };
        };
    };
    close $FH;

    foreach ( qw/ success naughty errors failed probed warning unknown info / ) {
        $count{total} += $count{$_} || 0;
    };
    print Dumper(\%count) if $verbose;

    return \%count;
};

sub _get_mail_log_location {

    # check the most common places
    my @log_files;
    push @log_files, 'maillog';       # freebsd
    push @log_files, 'mail.log';

    foreach ( @log_files ) {
        return "/var/log/$_" if -f "/var/log/$_";
    };

    warn "unable to find your mail logs.\n";
    return;
};


sub _parse_ftp_logs {
    my $logfile = _get_ftpd_log_location() or return;
    print "checking for FTP logins in $logfile\n" if $verbose;

# sample success
#Nov  8 11:27:51 vhost0 ftpd[29864]: connection from adsl-69-209-115-194.dsl.klmzmi.ameritech.net (69.209.115.194)
#Nov  8 11:27:51 vhost0 ftpd[29864]: FTP LOGIN FROM adsl-69-209-115-194.dsl.klmzmi.ameritech.net as rollins

# sample failed
#Nov 21 21:33:57 vhost0 ftpd[5398]: connection from 87-194-156-116.bethere.co.uk (87.194.156.116)
#Nov 21 21:33:57 vhost0 ftpd[5398]: FTP LOGIN FAILED FROM 87-194-156-116.bethere.co.uk

    open my $FH, '<', $logfile or warn "unable to read $logfile: $!\n" and return;
    my (%count, $rdns);
    while ( my $line = <$FH> ) {

        my ($mon, $day, $time, $host, $proc, $msg) = split /\s+/, $line, 6;

        next if ! $proc;
        next if $proc !~ /^ftpd/;

        if ( $rdns ) {
            # xferlog format has 'connection from' line followed by status
            if ( $msg =~ /FROM $rdns/i ) {
                $count{failed}++ if $line =~ /^FTP LOGIN FAILED/;
                $count{success}++ if $line =~ /^FTP LOGIN FROM/;
                $rdns = undef;
                next;
            };
        };

        ( $rdns ) = $msg =~ /connection from (.*?) \($ip\)/;
    };
    close $FH;

    foreach ( qw/ success failed / ) {
        $count{total} += $count{$_} || 0;
    };

    print Dumper(\%count) if $verbose;

    if ( $count{success} ) { do_whitelist(); return; };
    if ( $count{naughty} ) { do_blacklist(); return; };

    do_blacklist() if $count{total} > 10;
}

sub _get_ftpd_log_location {
    my @log_files;
    push @log_files, 'xferlog';      # freebsd, debian
    push @log_files, 'ftp.log';      # Mac OS X
    push @log_files, 'auth.log';

    foreach ( @log_files ) {
        return "/var/log/$_" if -f "/var/log/$_";
    };

    warn "unable to find FTP logs\n";
    return;
};


sub upgrade_to_db {
    my @files = glob "$root_dir/seen/*/*/*/*";
    return if ! @files;
    print "upgrading to DB format\n";

    foreach my $f ( @files ) {
        my $a_ip = join('.', (split /\//, $f)[-4,-3,-2,-1]);
        my $key = _get_db_key( $a_ip ) or die "unable to convert ip to an int";
        my $count = _count_lines( $f );
        my $white_path = $f; $white_path =~ s/seen/white/;
        my $black_path = $f; $black_path =~ s/seen/black/;
        print "$f \t $key $a_ip $count\n";
        $db_tie->{$key} = join('^', $count, -f $white_path ? 1 : 0, -f $black_path ? 1 : 0);
        unlink $white_path if -f $white_path;
        unlink $black_path if -f $black_path;
        unlink $f;
    };
    system "find $root_dir -type dir -empty -delete"
};

sub _init_db {
    $db_path = _get_db_location() or exit;
    $db_lock = _get_db_lock( $db_path ) or exit;
    $db_tie  = _get_db_tie( $db_path, $db_lock ) or exit;

    if ( ! $ip ) { print "no IP, skip info\n"; return; };

    $db_key  = _get_db_key() or die "unable to get DB key";
    if ( $db_tie->{ $db_key } ) {   # we've seen this IP before
        my @vals = _parse_db_val( $db_tie->{ $db_key } );
        $ip_record{seen}  = $vals[0];
        $ip_record{white} = $vals[1];
        $ip_record{black} = $vals[2];
    };
    printf "%4.0f connections from $ip (key: $db_key)\n", $ip_record{seen};
    print "\tand it is whitelisted\n" if $ip_record{white};
    print "\tand it is blacklisted\n" if $ip_record{black};
};

sub _parse_db_val {
    return split /\^/, shift;  # using ^ char as delimiter
};

sub _get_db_key {
    my $lip = shift || $ip;
    if ( $has_netip ) {
        return unpack 'N', pack 'C4', split /\./, $lip;  # works for IPv4 only
    };
    return Net::IP->new( $lip )->intip;
};

sub _get_db_tie {
    my ( $db, $lock ) = @_;

    tie( my %db, 'AnyDBM_File', $db, O_CREAT|O_RDWR, oct('0600')) or do {
        warn "error, tie to database $db failed: $!";
        close $lock;
        return;
    };
    return \%db;
};

sub _get_db_location {

    # Setup database location
    my @candidate_dirs = ( $root_dir, "/var/db/sentry", "/var/db", '.' );

    my $dbdir;
    for my $d ( @candidate_dirs ) {
        next if ! $d || ! -d $d;   # impossible
        $dbdir = $d;
        last;   # first match wins
    }
    my $db = "$dbdir/sentry.dbm";
    print "using $db as database\n" if $verbose;
    return $db;
};

sub _get_db_lock {
    my $db = shift;

    return _get_db_lock_nfs($db) if $nfslock;

    # Check denysoft db
    open(my $lock, '>', "$db.lock") or do {
        warn "error, opening lockfile failed: $!";
        return;
    };

    flock( $lock, LOCK_EX ) or do {
        warn "error, flock of lockfile failed: $!";
        close $lock;
        return;
    };

    return $lock;
}

sub _get_db_lock_nfs {
    my $db = shift;

    require File::NFSLock;

    ### set up a lock - lasts until object looses scope
    my $nfslock = new File::NFSLock {
        file      => "$db.lock",
        lock_type => LOCK_EX|LOCK_NB,
        blocking_timeout   => 10,      # 10 sec
        stale_lock_timeout => 30 * 60, # 30 min
    } or do {
        warn "error, nfs lockfile failed: $!";
        return;
    };

    open(my $lock, '+<', "$db.lock") or do {
        warn "error, opening nfs lockfile failed: $!";
        return;
    };

    return $lock;
};

sub ignore_this {};

__END__

=head1 NAME

Sentry - safe and effective protection against bruteforce attacks


=head1 SYNOPSIS

 sentry --ip=<ipv4 or ipv6 IP> [ --whitelist | --blacklist | --delist | --connect ]
 sentry --report [--verbose --ip=<ipv4 or ipv6 address> ]
 sentry --help
 sentry --update


=head1 ADDITIONAL DOCUMENTATION

See https://github.com/msimerson/sentry

=head1 DESCRIPTION

Sentry limits bruteforce attacks using minimal system resources.

=head2 SAFE

To prevent inadvertant lockouts, Sentry manages a whitelist of IPs that connect more than 3 times and succeed at least once. A forgetful colleague or errant script running behind the office NAT is far less likely to get the entire office locked out than with many bruteforce blockers.

Sentry includes firewall support for IPFW, PF, and ipchains. It is disabled by default. Be careful though, adding dynamic firewall rules may terminate existing sessions (attn IPFW users). Whitelist your IPs (connect 3x or use --whitelist) before enabling the firewall option.

=head2 SIMPLE

Sentry has a compact database for tracking IPs. It records the number of connects and the date when an IP was white or blacklisted.

Sentry is written in perl, which is installed practically everywhere sshd is. The only dependency is Net::IP for IPv6 handling. Sentry installation is extremely simple.

=head2 FLEXIBLE

Sentry supports blocking connection attempts using tcpwrappers and several popular firewalls. It is easy to extend Sentry to support additional blocking lists.

Sentry was written to protect the SSH daemon but is also used for FTP and SMTP protection. A primary attack platform is bot nets. The bots are used for carrying out SSH attacks as well as spam delivery. Blocking on multiple attack criteria reduces overall abuse.

The programming style of Sentry makes it easy to insert code for additional functionality.

=head2 EFFICIENT

A goal of Sentry is to minimize resource abuse. Many bruteforce blockers (denyhosts, fail2ban, sshdfilter) expect to run as a daemon, tailing a log file. That requires an interpreter to always be running, consuming CPU and RAM. A single hardware node with dozens of virtual servers loses hundreds of megs of RAM to daemon protection.

Sentry uses resources only when connections are made, and then only a few times before an IP is white/blacklisted. Once an IP is blacklisted for abuse, the resources it can abuse are neglible.

=head1 REQUIRED ARGUMENTS

=over 4

=item ip

An IPv4 or IPv6 address. The IP should come from a reliable source that is
difficult to spoof. Tcpwrappers is an excellent source. UDP connections
are a poor source as they are easily spoofed. The log files of TCP daemons
can be good source if they are parsed carefully to avoid log injection attacks.

=back

All actions except B<report> and B<help> require an IP address. The IP can
be manually specified by an administrator, or preferably passed in by a TCP
server such as tcpd (tcpwrappers), inetd, or tcpserver (daemontools).

=head1 ACTIONS

=over

=item blacklist

deny all future connections

=item whitelist

whitelist all future connections, remove the IP from the blacklists,
and make it immune to future connection tests.

=item delist

remove an IP from the white and blacklists. This is useful for testing
that Sentry is working as expected.

=item connect

register a connection by an IP. The connect method will log the attempt
and the time. See CONNECT.

=item update

Check the most recent version of Sentry against the installed version and update if a newer version is available.

=back

=head1 EXAMPLES

https://github.com/msimerson/sentry/wiki/Examples


=head1 NAUGHTY

Sentry has flexible rules for what constitutes a naughty connection. For SSH,
attempts to log in as an invalid user are considered naughty. For SMTP, the
sending of a virus, or an email with a high spam score could be considered
naughty. See the configuration section in the script related settings.


=head1 CONNECT

When new connections arrive, the connect method will log the attempt.
If the IP is already white or blacklisted, it exits immediately.

Next, Sentry checks to see if it has seen the IP more than 3 times. If so,
check the logs for successful, failed, and naughty attempts from that IP.
If there are any successful logins, whitelist the IP and exit.

If there are no successful logins and there are naughty ones, blacklist
the IP. If there are no successful and no naughty attempts but more than 10
connection attempts, blacklist the IP. See also NAUGHTY.


=head1 CONFIGURATION AND ENVIRONMENT

There is a very brief configuration section at the top of the script. Once
your IP is whitelisted, update the booleans for your firewall preference
and Sentry will update your firewall too.

Sentry does NOT make changes to your firewall configuration. It merely adds
IPs to a table/list/chain. It does this dynamically and it is up to the
firewall administrator to add a rule that does whatever you'd like with the
IPs in the sentry table.

See PF: https://github.com/msimerson/sentry/wiki/PF


=head1 DIAGNOSTICS

Sentry can be run with --verbose which will print informational messages
as it runs.

=head1 DEPENDENCIES

  Net::IP, for IPv6 support.

=head1 BUGS AND LIMITATIONS

The IPFW and ipchains code is barely tested.

Report problems to author.

=head1 AUTHOR

Matt Simerson (msimerson@cpan.org)


=head1 ACKNOWLEDGEMENTS

Those who came before: denyhosts, fail2ban, sshblacklist, et al


=head1 LICENCE AND COPYRIGHT

Copyright (c) 2015 The Network People, Inc. http://www.tnpi.net/

This module is free software; you can redistribute it and/or
modify it under the same terms as Perl itself. See L<perlartistic>.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.


