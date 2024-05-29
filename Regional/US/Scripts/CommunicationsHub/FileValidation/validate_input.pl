#!C:/perl5.10.1/bin/perl.exe

use v5.10;

use strict;
use warnings;

#--------------------------------------------------------------------------------------------------
# This script validates input datafiles.
# Files that are valid are moved to be processed.
# Invalid files are quarantined to a bad folder,
# Client gets an Email listing the validation error.
#
# This application runs in Aardvark using AardvarkAutoprocessingScriptSupervisor.pl as follows:
# cmd /c C:\perl5.10.1\bin\perl.exe
# %CCS_RESOURCE%\Regional\NA\Scripts\AardvarkAutoprocessingScriptSupervisor.pl
# \\csavcdsfpd1\GE\UAT\GitResource\Regional\US\Scripts\CommunicationsHub\PreProcessor\validate_input.pl
# --base  \\csavcdsfpd1\GE\UAT\DataIn\CommunicationsHub
# --good  Preprocess
# --bad   Invalid
# --type  XSD
# --std   COCC\COCC_Notices_XML_Schema.xsd
# --email 'computersharecyclenotifications@cocc.com'
# \\csavcdsfpd1\GE\UAT\DataIn\CommunicationsHub\In\TEST_20230301_1078_CO_ADDCHG_NOTICE.XML
#--------------------------------------------------------------------------------------------------

use Data::Dumper;
use Getopt::Long;
use FindBin qw($Bin);
use File::Copy qw(move);
use File::Basename;

use lib $ENV{CCS_RESOURCE};
use lib_CCS;
use CcsSmtp;

my $DefaultSenderName  = q{#NA CTG Operations&Support};
my $DefaultSenderEmail = q{nactgoperations&support@computershare.com};
my $DefaultRecipient   = q{!USCSBURProgramming@computershare.com};
my $EmailMessage       = q{
The input file  !FILENAME!  failed validation against the current XSD.

!VALIDATION_ERROR!
File processing has been aborted. Please correct the issue and send another file.

Thank You.
};
my $ErrorMessage;

GetOptions(
	'base=s'  => \my $BaseDir,
	'good=s'  => \my $GoodDir,
	'bad=s'   => \my $BadDir,
	'type=s'  => \my $FileType,
	'std=s'   => \my $ValidSTDFile,
	'email=s' => \my $Recipient,
	'pass'    => \my $PassThrough,
	'help'    => sub { usage(); exit 0 },
);

sub usage {
	my ($cmd) = $0 =~ /^.*?[\\\/]?([^\\\/]+?)(?:\.\w{1,4})?$/;

	print <<"EOF";
 $cmd: validates each XML file against specified XSD

Options:
  --base  <FOLDER>  base folder for file moves
  --good  <FOLDER>  valid XML file sub-folder
  --bad   <FOLDER>  invalid XML file sub-folder
  --type  <TYPE>    file type validation e.g. XSD
  --std   <FILE>    path to validation schema file
  --email <EMAIL>   recipient(s) for error email
  --pass            pass thru file to processing
  --help            print this usage message

EOF

	return;
}

sub isValidFile {
	my ( $input_file, $schema_file ) = @_;

	# build the command for run()
	my @command = ('C:/Strawberry/perl/bin/perl.exe');
	push @command, "$Bin/${FileType}_validation.pl";
	push @command, '--xsd', $schema_file, $input_file;

	# put the command line in the trace first
	say 'RUNNING: ' . join( ' ', @command );

	my $output = `@command`;
	( $ErrorMessage = $output ) =~ s/^VALIDATION?:.+$//mg;

	$output =~ /^VALIDATION:? (PASS|FAIL)$/mi;
	return { PASS => 1, FAIL => 0 }->{ uc $1 };
}

sub sendEmail {
	my %email = @_;

	$email{'name'} //= $email{'sender'};

	say "From:    $email{'name'}";
	say "         $email{'sender'}";
	say "To:      $email{'recipient'}";
	say "Subject: $email{'subject'}";
	say "\n$email{'body'}";

	CcsSmtp::SendMail(
		{
			fromdispname => $email{'name'},
			from         => $email{'sender'},
			to           => [ split /;/, $email{'recipient'} ],
			subject      => $email{'subject'},
			body         => [ $email{'body'} ],
		}
	);

	say "Email sent!";
	return;
}

## -------------------------------------- BEGIN main() ------------------------------------------##

if (
	not(   defined $BaseDir
		&& defined $GoodDir
		&& defined $BadDir
		&& defined $FileType
		&& defined $ValidSTDFile )
	)
{
	usage();
	die "Specify --base --good --bad folders, and --type --std file options.\n";
}

if ( not -d $BaseDir ) {
	die "No such --base dir '$BaseDir'\n";
}

mkdir "$BaseDir/$GoodDir" if not -d "$BaseDir/$GoodDir";
mkdir "$BaseDir/$BadDir"  if not -d "$BaseDir/$BadDir";

my $schema_file = "$BaseDir/$FileType/$ValidSTDFile";
if ( not -f $schema_file ) {
	die "No such validation schema file '$schema_file'\n";
}

if ( 0 == @ARGV ) {
	die "No input file specified.\n";
}

foreach my $input_file (@ARGV) {
	next if not -f $input_file;    # say "$input_file: No such file"

	if ( defined $PassThrough ) {
		say "XML Validation skipped, moving input file '$input_file' to '$BaseDir/$GoodDir'";
		move( $input_file, "$BaseDir/$GoodDir" ) or die "Failed to move '$input_file': $!\n";
	}
	else {
		say "Validating '$input_file' with '$FileType' Schema file '$schema_file'";
		if ( isValidFile( $input_file, $schema_file ) ) {
			say "Input file '$input_file' is valid; moving to '$BaseDir/$GoodDir'";
			move( $input_file, "$BaseDir/$GoodDir" ) or die "Failed to move '$input_file': $!\n";
		}
		else {
			say "Input file '$input_file' is invalid; moving to '$BaseDir/$BadDir'";
			move( $input_file, "$BaseDir/$BadDir" ) or die "Failed to move '$input_file': $!\n";

			my $filename = basename($input_file);
			$EmailMessage =~ s/!FILENAME!/$filename/o;
			$EmailMessage =~ s/!VALIDATION_ERROR!/$ErrorMessage/o;

			sendEmail(
				name      => $DefaultSenderName,
				sender    => $DefaultSenderEmail,
				recipient => $Recipient // $DefaultRecipient,
				subject   => "Input file '$filename' validation failure",
				body      => $EmailMessage,
			);
		}
	}
}

exit 0;

## --------------------------------------- END main() -------------------------------------------##
