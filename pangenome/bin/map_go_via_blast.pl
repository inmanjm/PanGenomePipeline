#!/usr/bin/env perl
use warnings;
use strict;
$|++;

=head1 NAME

map_go_via_blast.pl - map GO terms not covered by HMMs to centroids.

=head1 SYNOPSIS

    USAGE: map_go_via_blast.pl -P <project code> | --blast_local | --blast_file <blast file name>
                                --input_seqs <input fasta file>
                                [ --search_db <path to db> ] [ --evalue <evalue> ] 
                                [ --percent_id <percent identity> ] 
                                [ --percent_coverage <percent coverage> ]

=head1 OPTIONS

Choose ONE of the following THREE options:

=over 

B<--project, -P>      :   SGE/UGE grid accounting project code

B<--blast_local>      :   Do NOT run BLAST in parallel on a computing grid, but run it locally.

B<--blast_file, -b>   :   Skip BLAST, run using this results file instead.

=back

B<--search_db, -s>    :   Path to BLAST db for searching.

B<--evalue, -E>       :   e-value required to pass and be reported as a hit. [DEFAULT: 10e-5 ]

B<--percent_id, -I>   :   percent identity required to be reported as a hit. [DEFAULT: 35 ]

B<--percent_cov, -C>  :   min percent coverage required to be reported as a hit. [DEFAULT: 80 ]

B<--input_seqs, -i>   :   Input fasta file.

B<--use_nuc, -n>      :   Input is in nucleotide space, also use blastn.

=head1 DESCRIPTION

=head1 INPUT

=head1 OUTPUT

=head1 CONTACT

    Jason Inman
    jinman@jcvi.org

=cut

use Capture::Tiny qw{ capture_merged };
use Cwd;
use File::Path qw( mkpath remove_tree );
use FindBin;
use Getopt::Long qw( :config no_auto_abbrev no_ignore_case );
use IO::File;
use Pod::Usage;

use lib "$FindBin::Bin/../lib";
use grid_tasks;

my $BIN_DIR     = $FindBin::Bin;
my $BLASTN_EXEC = '/usr/local/packages/ncbi-blast+/bin/blastn';
my $BLASTP_EXEC = '/usr/local/packages/ncbi-blast+/bin/blastp';
my $BLASTDB_DIR = '/usr/local/scratch/PROK/jinman/PG-170';
my $BLASTN_DB   = "$BLASTDB_DIR/plasmid_finder_rep.seq";
my $BLASTP_DB   = "$BLASTDB_DIR/plasmid_finder_rep.pep";
my $SPLIT_FASTA = "$BIN_DIR/split_fasta.pl";

my $DEFAULT_EVALUE      = '10e-5';
my $DEFAULT_PERCENT_ID  = '35';
my $DEFAULT_PERCENT_COV = '80';

my %opts;
GetOptions( \%opts,
            'project|P=s',
            'blast_local',
            'blast_file|b=s',
            'input_seqs|i=s',
            'search_db|s=s',
            'evalue|E=s',
            'percent_id|I=i',
            'percent_cov|C=i',
            'use_nuc|n',
            'working_dir|w=s',
            'log_dir=s',
            'help|h',
        ) || die "Problem getting options.\n";
pod2usage( { -exitval => 1, -verbose => 2 } ) if $opts{ help };

check_options();

# Run blast on the input, if required.
my $blast_file;
if ( $opts{ blast_file } ) {

    $blast_file = $opts{ blast_local };

} else {

    $blast_file = "$opts{ working_dir }/blast_output";

    my $blast_prog = $opts{ use_nuc } ? $BLASTN_EXEC : $BLASTP_EXEC;
    my $blast_db = $opts{ blast_db } // $opts{ use_nuc } ? $BLASTN_DB : $BLASTP_DB;
    my $blast_cmd = "$blast_prog -db $blast_db -evalue $opts{ evalue }"; 
    $blast_cmd .=   " -qcov_hsp_perc $opts{ percent_cov }";
    $blast_cmd .=   " -perc_identity $opts{ percent_id }" if ( $opts{ use_nuc } );
    $blast_cmd .=   " -outfmt \"6 qseqid sseqid pident length mismatch gapopen qstart qend sstart send evalue bitscore\"";

    if ( $opts{ blast_local } ) {

        # add in the query
        $blast_cmd .= " -query $opts{ input_seqs } -out $blast_file";

        #   Run the blast
        my $lf = "$opts{ log_dir }/blast.log";
        my $lh = IO::File->new( $lf, "w+" ) || die( "Couldn't open $lf for logging: $!\n" );
 
        capture_merged{

            system( $blast_cmd ) == 0 || die( "Problem running blast.  See $lf\n" );

        } stdout => $lh;

    } else {

        # Going to run blast on the grid.
        my $blast_dir = "$opts{ working_dir }/blast";
        my $split_dir = "$blast_dir/split_fastas";
        mkpath( $split_dir ) unless ( -d $split_dir );
        my $split_cmd = "$SPLIT_FASTA -f $opts{ input_seqs } -n 1000 -o $split_dir";

        unless ( system( $split_cmd ) == 0 ) {

            # something went wrong and we should check the results carefully.
            # Check for errors of the type "Expected: unique FASTA identifier" in split_fasta.log
            my $split_fasta_log = "$opts{ working_dir }/split_fasta.pl.error";
            my $found_dupe = 0;
            if ( -s $split_fasta_log ) {

                open( my $sflh, '<', $split_fasta_log ) || die "Can't open $split_fasta_log to investigate split_fasta.pl failure\n";
                while( <$sflh> ) {

                    $found_dupe++ if (/Expected: unique FASTA identifier/);

                }

            }

            my $dupe_message = ( $found_dupe ) ?
                                "It looks like duplicate locus tags are invovled.\n" :
                                "It doesn't look like duplicate locus tags are invovled.\n";

            die( "Error running split_fasta.  $dupe_message\n");

        }

        # Write shell script
        my @file_list = <$split_dir/split_fasta.*>;
        my $sh_file = write_blast_shell_script( $blast_file, $split_dir, $blast_dir, $blast_cmd );
        print "Running blast on the grid.\n";

        # Launch blast job array, wait for finish
        my @grid_jobs;
        push( @grid_jobs, launch_grid_job( $opts{ project }, $opts{ working_dir }, $sh_file, 'blast.stdout', 'blast.stderr', "", scalar @file_list ) );
        print "Waiting for blast jobs to finish.\n";
        wait_for_grid_jobs_arrays( \@grid_jobs, 1, scalar( @file_list ) ) if ( scalar @grid_jobs );
        print "Blast jobs finished!\n";

        # Cat all blast files together
        open( my $cfh, ">", $blast_file ) || die ( "Couldn't open $blast_file for writing: $!\n" );
        _cat( $cfh, glob( "$blast_dir/blast_output.*" ) );
        close $cfh; # Force the buffer to flush to the output file so it can be seen as non-empty sooner
                    # rather than later.

        if ( -e $blast_file ) {

            print "Removing intermediate blast files.\n";

            # Remove intermediate blast dir.
            remove_tree( $blast_dir, 0, 1 );

        } else {

            die( "Problem getting blast results.\n");

        }

        if ( -z $blast_file ) {

            print "No results from blast\n";
            exit(0);

        }

    }

}

# Parse blast output ( $blast_file, now ).

print "BLAST results at: $blast_file\n";

open( my $bfh, '<', $blast_file ) || die "Can't open $blast_file for reading: $!\n";

while( <$bfh> ) {

    # Parsing here should take a look at headers...
    # The idea is that we'll have a mapping of the accessions to GO terms stored somewhere,
    # Perhaps in the headers themselves?

}



exit(0);


sub write_blast_shell_script {

    my ( $fasta, $sdir, $bdir, $cmd ) = @_;

    my $cmd_string = $cmd . " -query $sdir" . '/split_fasta.$SGE_TASK_ID ' . "-out $bdir" . '/blast_output.$SGE_TASK_ID';
    my $script_name = "$bdir/grid_blast.sh";

    open( my $gsh, '>', $script_name ) || _die( "Can't open $script_name: $!\n", __LINE__ );

    print $gsh "#!/bin/tcsh\n\n";
    print $gsh "$cmd_string\n";

    chmod 0755, $script_name;

    return $script_name;
}


sub _cat {
# Given a list of file names, concatonate the first through n minus one-th
# onto the nth.
    
    my ( $output_fh, @input ) = ( @_ );
    
    for ( @input ) {
        if(-s $_){
            open ( my $ifh, '<', $_ );
            while ( <$ifh> ) { print $output_fh $_ };
        }
    }
}


sub check_options {

    my $errors = '';

    # Only want one of ( --project --blast_local --blast_file )
    if ( ( $opts{ project } && ( $opts{ blast_local } || $opts{ blast_file } ) ) ||
         ( $opts{ blast_local } && $opts{ blast_file } ) ) {
        $errors .= "Please specifiy only one of --project, --blast_local, or --blast_file\n";
    }

    # But must have one of them.
    unless ( $opts{ project } || $opts{ blast_local } || $opts{ blast_file } ) {
        $errors .= "Please specify one of --project, --blast_local, or --blast_file\n";
    }

    # If blast_file, make sure it exists:
    if ( $opts{ blast_file } ) {
        unless ( -s $opts{ blast_file } ) {
            $errors .= "--blast_file $opts{ blast_file } has no size or doesn't exists.\n";
        }
    }

    # Gotta have an input file or this is pointless.
    if ( $opts{ input_seqs } ) {
        unless( -s $opts{ input_seqs } ) {
            $errors .= "input seq file $opts{ input_seqs } is empty or non-existant.\n";
        }
    } else {
        $errors .= "--input_seqs is necessary.\n";
    }

    # These params have defaults:
    $opts{ evalue }      = $opts{ evalue }      // $DEFAULT_EVALUE;
    $opts{ percent_id }  = $opts{ percent_id }  // $DEFAULT_PERCENT_ID;
    $opts{ percent_cov } = $opts{ percent_cov } // $DEFAULT_PERCENT_COV;

    $opts{ working_dir } = $opts{ working_dir } // getcwd();
    $opts{ log_dir }     = $opts{ log_dir }     // getcwd();

    die $errors if $errors;

}