#!/usr/bin/env sh

# Bash script to make a pan-chromosome circular figure after gene_order.pl has been run.

# Usage: make_pan-chromosome_fig.sh <complete_path_to_pan-genome_base_directory>

# declare variables
base_dir=$1
results_dir="$base_dir/results/fGIs"
# required files
core_att="Core.attfGI"
share_clust="shared_clusters.txt"

# Will want to change srcdir to the pan-genome bin directory
script_name=$(readlink -f "$0")
src_dir=$(dirname $script_name)

cd $results_dir
echo "path = $results_dir"
echo "Generating files for circle making ..."
$src_dir/make_db2circle_genome_att.pl -a $core_att -c $share_clust

echo "Making xfig pan-chromosome file ..."
$src_dir/db2circle_rainbow_flatfile.spl -G genome.att -c config.file -F data.file > pan-chromosome.fig

echo "Converting to .pdf ..."
/usr/bin/fig2dev -L pdf pan-chromosome.fig pan-chromosome.pdf

echo "Finished making the pan-chromosome circular figure."
exit