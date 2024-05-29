#!C:/Strawberry/perl/bin/perl.exe

use v5.32;

use strict;
use warnings;

#change for master

## ------------------------------- BEGIN Program Description ------------------------------------##
#
# This script converts input datafile(s) using the specified harness and converter.
# Currently, converted output files are assumed to be in .JSON format.
# The process invokes a helper script 'get_job_details.pl' to obtain:
#    1) the job bag details aka stream_setup.xml file
#    2) the quadient content object aka qco.json file
# Finally, it builds a startup file and invokes InspireRunJob for doc composition.
#
# This application runs as follows:
# C:\Strawberry\perl\bin\perl.exe \
#   connect2_convert.pl           \
#     --converter  <Converter>    \
#     --contract   <ClientJob>    \
#     --inspirejob <InspireJob>   \
#     --inspireenv <InspireEnv>   \
#       <input_data_file>
#
# Alternatively, an Aardvark style --startupfile <StartupFile> option can be specified.
# <StartupFile> contains the following key=value parameters:
# DataFileName=<input_data_file>
# JobNumber=<ClientJob>
# RunNumber=<client_run>
# Extras=--inspirejob <InspireJob> --converter <Converter> --inspireenv <InspireEnv>
#
# <StartupFile> is parsed to extract all required options
# Most required command line options come from <StartupFile>
# Remaining required command line options are parsed from 'Extras' key in <StartupFile>
#
## --------------------------------- END Program Description ------------------------------------##

use Data::Printer;
use Getopt::Long;
use FindBin qw($Bin);
use IPC::Run qw(run);
use File::Copy;
use File::Basename;
use Date::Format;
use JSON;

## --------------------------------- BEGIN Global variables -------------------------------------##

my $INI_file = "$Bin/PreProcessor.ini";

my %Options = (
	'startupfile=s' => \my $StartupFile,
	'contract=s'    => \my $ClientJob,
	'converter=s'   => \my $Converter,
	'inspirejob=s'  => \my $InspireJob,
	'inspireenv=s'  => \my $InspireEnv,
	'startuponly'   => \my $StartupOnly,
	'help'          => sub { usage(); exit 0 },
);

my %PP_startup;
my $CHUB_ini;

## ---------------------------------- END Global variables --------------------------------------##
## -------------------------------------- BEGIN main() ------------------------------------------##

GetOptions(%Options);
my $DataFileName = $ARGV[0];

if ( defined $StartupFile ) {
	%PP_startup = parse_startupfile($StartupFile);

	$DataFileName = $PP_startup{'DataFileName'};
	$ClientJob    = $PP_startup{'JobNumber'};

	#hack $PP_startup{'JobDescription'} =~ / DEV / and $InspireEnv = 'development';

	if ( defined $PP_startup{'Extras'} ) {
		Getopt::Long::GetOptionsFromString( $PP_startup{'Extras'}, %Options );
	}

	say "Preprocessor startup: ", np %PP_startup;
}

die "No input file specified! Use --help for usage\n"
	if not defined $DataFileName;

die "Specify a contract number with --contract. Use --help for usage\n"
	if not defined $ClientJob;

die "Specify a contract number with --inspirejob. Use --help for usage\n"
	if not defined $InspireJob;

die "Specify a converter with --converter. Use --help for usage\n"
	if not defined $Converter;

$CHUB_ini = handle_ini_file($INI_file);
say "Communications Hub ini: ", np $CHUB_ini;

die "Invalid Communications Hub contract code '$InspireJob'\n"
	if $InspireJob !~ /^$CHUB_ini->{'general'}{'commhub_contract'}\d+$/;

$InspireEnv //= $CHUB_ini->{'helper'}{'get_ccs_setting'}->('gold_env');

die "No such inspire_env '$InspireEnv' specified in '$INI_file'\n"
	if not exists $CHUB_ini->{'inspire_env'}{$InspireEnv};

die "Missing Converter '$Converter' specification in '$INI_file'\n"
	if not exists $CHUB_ini->{'converter'}{$Converter};

# build InspireRunJob startup file from Preprocessor startup
my $inspire_startup_file = build_startupfile();

# call InspireRunJob.exe with the Inspire Startup File
my @inspire_runjob_cmd = ( $CHUB_ini->{'general'}{'inspire_runjob'} );
push @inspire_runjob_cmd, '--startupfile', $inspire_startup_file;
say 'RUNNING: ' . join( ' ', @inspire_runjob_cmd );

# exit if --startuponly is set; this is to test startup file creation only
die "Option --startuponly set. Exiting\n" if defined $StartupOnly;

run \@inspire_runjob_cmd;

exit 0;

## --------------------------------------- END main() -------------------------------------------##

sub parse_startupfile {
	my $startupfile = shift;

	if ( not -f $startupfile ) {
		die "startup file '$startupfile' not found!\n";
	}

	my %parsed;

	open my $STARTUPFH, '<', $startupfile
		or die "Failed to read startup file '$startupfile': $!\n";

	while (<$STARTUPFH>) {
		s/\r?\n$//ms;
		s/\s+$//;
		my ( $key, $value ) = split /=/, $_, 2;

		# more Perl-y
		$value = undef if '(null)' eq $value;

		# handle generically
		if ( exists $parsed{$key} ) {
			if ( ref $parsed{$key} ) {
				push @{ $parsed{$key} }, $value;
			}
			else {
				$parsed{$key} = [ $parsed{$key}, $value ];
			}
		}
		else {
			$parsed{$key} = $value;
		}
	}

	close $STARTUPFH;

	if ( defined $parsed{'ErrorFile'} ) {
		say "REDIRECTING STDERR to '$parsed{ErrorFile}'";
		open STDERR, '>>', $parsed{'ErrorFile'}
			or die "ERROR redirecting STDERR: $!";
		STDERR->autoflush(1);
	}
	else {
		die "ERROR redirecting STDERR: $!";
	}

	if ( defined $parsed{'TraceFile'} ) {
		say "REDIRECTING STDOUT to '$parsed{TraceFile}'";
		open STDOUT, '>>', $parsed{'TraceFile'}
			or die "ERROR redirecting STDOUT: $!";
		STDOUT->autoflush(1);
	}
	else {
		die "ERROR redirecting STDOUT: $!";
	}

	return %parsed;
}

sub handle_ini_file {
	my $ini_file = shift;

	if ( not -f $ini_file ) {
		die "INI file '$ini_file' not found!\n";
	}

	open my $INIFH, '<', $ini_file
		or die "Failed to read INI file '$ini_file': $!\n";

	my $init;
	my $section = 'general';

	while (<$INIFH>) {
		s/\r?\n$//ms;
		s/\s+$//;

		next if /^#/ || /^$/;

		if (/^\[(\w+)\]$/) {
			$section = $1;
			next;
		}

		my ( $key, $value ) = split /=/, $_, 2;

		$value = undef if '(null)' eq $value;
		$value = [ split( ',', $value ) ] if $value =~ /,/;

		$init->{$section}{$key} = $value;
	}

	close $INIFH;

	my $irje = $init->{'general'}{'inspire_runjob'};
	$irje =~ s/\%(\w+)\%/$ENV{$1}/e;
	$irje =~ s/\\/\//g;
	die "No such executable '$irje'\n" if not -x $irje;
	$init->{'general'}{'inspire_runjob'} = $irje;

	foreach my $key ( keys %{ $init->{'stack'} } ) {
		my $exe = $init->{'stack'}{$key};
		$exe =~ s/\%(\w+)\%/$ENV{$1}/e;
		$exe =~ s/\\/\//g;
		die "No such executable '$exe'\n" if not -x $exe;
		$init->{'stack'}{$key} = $exe;
	}

	# validate the converter harnesses
	foreach my $key ( keys %{ $init->{'harness'} } ) {
		my ( $stack, $script ) = @{ $init->{'harness'}{$key} };
		die "Invalid stack '$stack' for harness '$key'\n"
			if not exists $init->{'stack'}{$stack};
		$stack  = $init->{'stack'}{$stack};
		$script = "$Bin/$script";
		die "No such script '$script'\n" if not -f $script;
		$init->{'harness'}{$key} = [ $stack, $script ];
	}

	# also, validate the 'helper' scripts
	foreach my $key ( keys %{ $init->{'helper'} } ) {
		my ( $stack, $script ) = @{ $init->{'helper'}{$key} };
		die "Invalid stack '$stack' for helper '$key'\n"
			if not exists $init->{'stack'}{$stack};
		$stack  = $init->{'stack'}{$stack};
		$script = "$Bin/$script";
		die "No such script '$script'\n" if not -f $script;
		$init->{'helper'}{$key} = sub {
			my @command = ( $stack, $script, @_ );
			say 'RUNNING: ' . join( ' ', @command );
			run \@command, '>', \my $output;
			return $output;
		};
	}

	foreach my $key ( keys %{ $init->{'converter'} } ) {
		my $harness = $init->{'converter'}{$key}[0];
		die "Invalid harness '$harness' for converter '$key'\n"
			if not exists $init->{'harness'}{$harness};
		die "Invalid / missing Q2G_type for converter '$key'\n"
			if not defined $init->{'converter'}{$key}[1];
	}

	return $init;
}

sub convert_input {
	my ( $client_job, $client_run ) = @_;

	my $filename = basename($DataFileName);
	move $DataFileName, '.'
		or die "Could not move '$filename' to current dir: $!\n";

	my $harness = $CHUB_ini->{'converter'}{$Converter}[0];

	# build the command for run()
	my @command = @{ $CHUB_ini->{'harness'}{$harness} };
	push @command, '--converter', $Converter;
	push @command, '--contract',  $client_job;
	push @command, '--run',       $client_run;
	push @command, '--file',      $filename;

	say 'RUNNING: ' . join( ' ', @command );
	run \@command, '>', \my $output;
	say $output;

	my $jsonfile;
	while ( $output =~ /^(.+) -> (.+)$/mg ) {
		if ( $1 eq $filename ) {
			$jsonfile = $2;
			last;
		}
	}

	die "'$Converter' converter failed to convert '$filename'\n"
		if !( defined $jsonfile && -f $jsonfile && $jsonfile =~ /\.json$/i );

	return ( $filename, $jsonfile );
}

sub build_startupfile {
	my $today = time2str( '%A, %B %d, %Y', time );

	my %inspire_startup = ( $ENV{'AREA'} eq 'DEVELOPMENT' && $ENV{'DEVELOPMENT'} ) || defined $StartupOnly
		? (
		# initialize startupfile for DEVELOPMENT environment or --startuponly

		EmailAddresses_FailedToQueue => $CHUB_ini->{'default'}{'support_email'},
		EmailAddresses_Failed        => $CHUB_ini->{'default'}{support_email},

		ComputerName   => $ENV{'COMPUTERNAME'},
		UserName       => "$ENV{'USERDOMAIN'}\\$ENV{'USERNAME'}",
		ProcessingDate => $today,
		LastUpdate     => $today,

		SLAProcessCode  => 'All',
		Product         => '(null)',
		Package         => '(null)',
		PackageType     => '(null)',
		PackageVersion  => '(null)',
		ExternalDBJobId => '(null)',

		TestFlag         => 0,
		JobId            => 0,
		JobStatusId      => 0,
		JobQueueId       => 0,
		LinkedJobQueueId => 0,
		ProcessId        => 0,
		Priority         => 1,
		)
		: %PP_startup;    # else, duplicate the preprocessor startupfile

	$inspire_startup{'ProcessingScript'} = $CHUB_ini->{'general'}{'inspire_runjob'};

	# Client contract run number:
	# if --startuponly is specified, then use default value from INI file
	# else if development environment, then get run number uding Aardvark web service
	# else if Aardvark startupfile is used, then get run number from the startupfile
	# otherwise, the application stops
	my $client_run =
		defined $StartupOnly ? $CHUB_ini->{'default'}{'client_run_number'}
		: ( $ENV{'AREA'} eq 'DEVELOPMENT' && $ENV{'DEVELOPMENT'} )
		? $CHUB_ini->{'helper'}{'get_client_run_num'}->($ClientJob)
		: $PP_startup{'RunNumber'};

	die "Missing or Invalid Client Run Number '$client_run'\n"
		if not( defined $client_run && $client_run =~ /^\d+$/ );

	my $inspire_run =
		defined $StartupOnly
		? $CHUB_ini->{'default'}{'inspire_run_number'}
		: $CHUB_ini->{'helper'}{'get_chub_run_num'}->( $InspireJob, $InspireEnv, $ClientJob, $client_run );

	die "Missing or Invalid Inspire Run Number '$inspire_run'\n"
		if !( defined $inspire_run && $inspire_run =~ /^\d+$/ );

	$inspire_startup{'JobNumber'}  = $InspireJob;
	$inspire_startup{'ClientCode'} = $CHUB_ini->{'general'}{'commhub_contract'};
	$inspire_startup{'RunNumber'}  = $inspire_run;

	# convert the input data to JSON using harness and converter module
	my ( $inputfile, $outputfile ) = convert_input( $ClientJob, $client_run );

	# build the additional encompass quadient content object JSON file
	my $qco_json_file = "${ClientJob}.${client_run}.QCO.json";
	my $qco_json_str  = $CHUB_ini->{'helper'}{'get_encompass_qco'}->($ClientJob);
	open my $qco_fh, '>', $qco_json_file or die "Failed to open '$qco_json_file': $!\n";
	print $qco_fh $qco_json_str;
	close $qco_fh;

	$inspire_startup{'DataFileName'} = [ $inputfile, $outputfile, $qco_json_file ];

	$outputfile =~ /\.(\w+)\.json$/i and my $doc_type = $1;

	$inspire_startup{'JobDescription'} = "$InspireJob - Step 4 - Communication Hub ";
	$inspire_startup{'JobDescription'} .= ( $InspireEnv =~ /^dev/i ? 'DEV ' : 'QA ' ) if $InspireEnv !~ /^prod/i;
	$inspire_startup{'JobDescription'} .= "- $ClientJob Run #$client_run $doc_type - Run #$inspire_run";

	# now, let's construct this very long Extras argument for the Inspire job
	#Extras= \
	# --aardvarkAppAdminUri https://CSAVARDWEBt...    <-- from get_job_details()
	# --addJobQueue         true                      <-- CONSTANT
	# --environment         ccsccmusbld01             <-- command line option --inspireenv
	# --icmRegion           US                        <-- CONSTANT
	# --jobConfigName       JobConfig_${doc_type}.xml <-- $doc_type is from JSON filename
	# --q2g                 true                      <-- CONSTANT
	# --site                processing                <-- from get_job_details()
	# --streamSetupXML      stream_setup.xml          <-- from get_job_details()

	my $stream_setup_xml = "stream_setup_${ClientJob}_${client_run}.xml";
	open my $ssx_fh, '>', $stream_setup_xml or die "Failed to open '$stream_setup_xml': $!\n";
	print $ssx_fh $CHUB_ini->{'helper'}{'get_stream_setup'}->($ClientJob);
	close $ssx_fh;

	( my $job_config_name = $outputfile ) =~ s/\.(\w+)\.json$/JobConfig_$1.xml/;

	my $get_ccs_setting = $CHUB_ini->{'helper'}{'get_ccs_setting'};

	my %startup_extras = (
		streamSetupXML      => $stream_setup_xml,
		site                => $get_ccs_setting->('site'),
		aardvarkAppAdminUri => $get_ccs_setting->('aardvark_web_svc_appadmin_proxy'),
		environment         => $CHUB_ini->{'inspire_env'}{ lc $InspireEnv },
		jobConfigName       => "JobConfig_${doc_type}.xml",
		addJobQueue         => 'true',
		q2g                 => 'true',
		icmRegion           => 'US',
	);

	$inspire_startup{'Extras'} = join( ' ', map { "--$_ $startup_extras{$_}" } sort keys %startup_extras );

	my $today_and_now = time2str( '%j.%H%M%S', time );
	my $startup_filename = "${InspireJob}.${inspire_run}.${today_and_now}.startup.txt";

	$inspire_startup{'StartupFileName'} = $startup_filename;
	( $inspire_startup{'ProgressFile'} = $startup_filename ) =~ s/startup/progress/;
	( $inspire_startup{'TraceFile'}    = $startup_filename ) =~ s/startup/trace/;
	( $inspire_startup{'ErrorFile'}    = $startup_filename ) =~ s/startup/error/;

	# adding custom key to be used later in Q2G
	$inspire_startup{'_requireSignOffYN'} =
		decode_json($qco_json_str)->{'content'}{'data'}[0]{'operations_details'}{'requires_approval_yn'} || 'No';
	$inspire_startup{'_Q2GType'} = $CHUB_ini->{'converter'}{$Converter}[1];

	say "InspireRunJob startup: ", np %inspire_startup;

	open my $startup_fh, '>', $startup_filename or die "Failed to open $startup_filename: $!\n";

	foreach my $key ( sort keys %inspire_startup ) {
		my $value = $inspire_startup{$key};
		next if not defined $value;

		if ( ref($value) eq 'ARRAY' ) {
			map { print $startup_fh "$key=$_\n" } sort @{$value};
		}
		else {
			print $startup_fh "$key=$value\n";
		}
	}

	close $startup_fh;

	say "Created InspireRunJob startup file '$startup_filename'";
	return $startup_filename;
}

sub usage {
	my ($cmd) = $0 =~ /^.*?[\\\/]?([^\\\/]+?)(?:\.\w{1,4})?$/;

	print <<"EOF";
 $cmd: Calls the specified tech stack harness to convert a file

Options:
  --startupfile  <FILE>         Aardvark auto-proc startup file

Development Options:
  --contract     <CONTRACT>     client job number
  --inspirejob   <CONTRACT>     Communications Hub contract code
  --converter    <CONVERTER>    converter name (see .ini file)
  --inspireenv   <GOLD_ENV>     inspire env e.g. uat (optional)

  --startuponly                 build inspire INIFH file only; 
                                do not execute InspireRunJob
  --help                        print this usage message
EOF

	return;
}
