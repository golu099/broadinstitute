version 1.0 
##FN 
#qiime2022.8 version
#QIIME WORKLOW PART 1.A
#1.samtools (universal)
#2. cutadapt 
#3. vsearch 
#4. deblur
#5. 

#Part 1A | Step 1: BAM -> QZA
#qiime import bam-(fastq)-> qza 
task qiime_import_from_bam {

    meta{
        description: "Alignments in the SAM format, including sorting, merging, indexing and generating alignments in a per-position format."
    }

    input { 
        File    reads_bam
        String  sample_name = basename(reads_bam, '.bam')

        String  docker     = "quay.io/qiime2/core:2022.8" 
    }

    parameter_meta {
        reads_bam: {description: "Input BAM file"}
    }

    command <<<
        set -ex -o pipefail
        # obtain the name of the qiime conda environment in the container; flexible about version
        CONDA_ENV_NAME=$(conda info --envs -q | awk -F" " '/qiime.*/{ print $1 }')
        # activate the qiime conda environment
        # seemingly necessary because of:
        #   https://github.com/chanzuckerberg/miniwdl/issues/603
        conda activate ${CONDA_ENV_NAME}


        #Part 1A | BAM -> FASTQ [Simple samtools command]
        samtools fastq -1 $(pwd)/R1.fastq.gz -2 $(pwd)/R2.fastq.gz -0 /dev/null ~{reads_bam}
        #making new bash variable | regex: (_) -> (-)
        NEWSAMPLENAME=$(echo "~{sample_name}" | perl -lape 's/[_]/-/g')
        #All names added to one giant file 
        echo ${NEWSAMPLENAME} > NEWSAMPLENAME.txt
        #Make a manifest.txt that contains [1.sample-id 2.R1-fastq 3.R2.fastq]
        #> =overwrite or writes new file 
        echo -e "sample-id\tforward-absolute-filepath\treverse-absolute-filepath" > manifest.tsv
        #>>= appends 
        #\t= tabs next value 
        echo -e "$NEWSAMPLENAME\t$(pwd)/R1.fastq.gz\t$(pwd)/R2.fastq.gz" >> manifest.tsv
        
        #fastq -> bam (provided by qiime tools import fxn)
        qiime tools import \
            --type 'SampleData[PairedEndSequencesWithQuality]' \
            --input-path manifest.tsv \
            --input-format PairedEndFastqManifestPhred33V2 \
            --output-path "~{sample_name}.qza"
    >>>

    output {
        File   reads_qza               = "~{sample_name}.qza"
        String samplename_master_sheet = read_string("NEWSAMPLENAME.txt")
    }

    runtime {
        docker: "~{docker}"
        memory: "1GB"
        cpu: 1 
    }
}

#--------------------------------------------
#Part 1 | Step 2:cutadapt: Trim sequences 
#trimreads-trim
#trim = default 
task trim_reads {

    meta {
        description:"Removing adapter sequences, primers, and other unwanted sequence from sequence data."
    }

    input {
        File    reads_qza
        
        String  qza_basename = basename(reads_qza, '.qza')
        #Boolean not-default = false
        String  forward_adapter         = "CTGCTGCCTCCCGTAGGAGT"
        String  reverse_adapter         = "AGAGTTTGATCCTGGCTCAG"
        Int    min_length              = 1
        Boolean? keep_untrimmed_reads   = false

        String  docker          = "quay.io/qiime2/core:2022.8" 
    }

    command <<<
        set -ex -o pipefail
        # obtain the name of the qiime conda environment in the container; flexible about version
        CONDA_ENV_NAME=$(conda info --envs -q | awk -F" " '/qiime.*/{ print $1 }')
        # activate the qiime conda environment
        # seemingly necessary because of:
        #   https://github.com/chanzuckerberg/miniwdl/issues/603
        conda activate ${CONDA_ENV_NAME}

        qiime cutadapt trim-paired \
        --i-demultiplexed-sequences "~{reads_qza}" \
        --p-front-f "~{forward_adapter}" \
        --p-front-r "~{reverse_adapter}" \
        ~{"--p-minimum-length " + min_length} \
        ~{true='--p-no-discard-untrimmed' false='--p-discard-untrimmed' keep_untrimmed_reads} \
        --o-trimmed-sequences "~{qza_basename}_trimmed.qza"

        #trim-visual 
        qiime demux summarize \
        --i-data "~{qza_basename}_trimmed.qza" \
        --o-visualization "~{qza_basename}_trim_summary.qzv"
    >>>

    output {
        #trimmed-sequences = paired ends for vsearch
        File trimmed_reads_qza     = "~{qza_basename}_trimmed.qza"
        File trimmed_visualization = "~{qza_basename}_trim_summary.qzv" 
    }

    runtime {
        docker: "~{docker}"
        memory: "10 GB"
        cpu: 1
    }
}

#Part 1 | Step 3:VSEARCH: Merge sequences 
task merge_paired_ends { 
    meta {
        description: "Join paired-end sequence reads using vseach's merge_pairs function."
    }
    input {
        #Input File: Merge paired reads
        File    reads_qza
        String  reads_basename = basename(reads_qza, '.qza')

        String  docker = "quay.io/qiime2/core:2022.8"
    }

    command <<< 
        set -ex -o pipefail
        # obtain the name of the qiime conda environment in the container; flexible about version
        CONDA_ENV_NAME=$(conda info --envs -q | awk -F" " '/qiime.*/{ print $1 }')
        # activate the qiime conda environment
        # seemingly necessary because of:
        #   https://github.com/chanzuckerberg/miniwdl/issues/603
        conda activate ${CONDA_ENV_NAME}

        qiime vsearch join-pairs \
        --i-demultiplexed-seqs "~{reads_qza}" \
        --o-joined-sequences "~{reads_basename}_joined.qza"

        #Visualize 
        # may want "~{reads_qza}" as input, depending
        qiime demux summarize \
        --i-data "~{reads_basename}_joined.qza" \
        --o-visualization "~{reads_basename}_visualization.qzv"
    >>>
    output {
        File joined_end_outfile       = "~{reads_basename}_joined.qza"
        File joined_end_visualization = "~{reads_basename}_visualization.qzv"
    }
    runtime {
        docker: "~{docker}"
        memory: "1 GB"
        cpu: 1
    }
}

task gen_feature_table {

    meta {
        description: "Perform sequence quality control for Illumina data using the Deblur workflow with a 16S reference as a positive filter."
        }
    input {
        File    joined_end_outfile
        String  joined_end_basename = basename(joined_end_outfile, '.qza')
        Int trim_length_var = 300     
        String  docker = "quay.io/qiime2/core:2022.8"
    }
    command <<< 
        set -ex -o pipefail
        # obtain the name of the qiime conda environment in the container; flexible about version
        CONDA_ENV_NAME=$(conda info --envs -q | awk -F" " '/qiime.*/{ print $1 }')
        # activate the qiime conda environment
        # seemingly necessary because of:
        #   https://github.com/chanzuckerberg/miniwdl/issues/603
        conda activate ${CONDA_ENV_NAME}
            qiime deblur denoise-16S \
            --i-demultiplexed-seqs ~{joined_end_outfile} \
            ~{"--p-trim-length " + trim_length_var} \
            --p-sample-stats \
            --o-representative-sequences "~{joined_end_basename}_rep_seqs.qza" \
            --o-table "~{joined_end_basename}_table.qza" \
            --o-stats "~{joined_end_basename}_stats.qza"
            
            #Generate feature table- give you the number of features per sample 
            qiime feature-table summarize \
            --i-table  "~{joined_end_basename}_table.qza" \
            --o-visualization   "~{joined_end_basename}_table.qzv"
            #Generate visualization of deblur stats
            qiime deblur visualize-stats \
            --i-deblur-stats "~{joined_end_basename}_stats.qza" \
            --o-visualization "~{joined_end_basename}_stats.qzv"
        >>>
    output {
        #how many output files do i need
        File rep_seqs_outfile = "~{joined_end_basename}_rep_seqs.qza"
        File rep_table_outfile = "~{joined_end_basename}_table.qza"
        File feature_table = "~{joined_end_basename}_table.qzv"
        File visualize_stats = "~{joined_end_basename}_stats.qzv"

    }
    runtime {
        docker: "~{docker}"
        memory: "10 GB"
        cpu: 1
    } 
}
task train_classifier {
    meta {
        descrription: " Upload a classidier trained to classify v1-2 amplicon sequences"
    }
    input {
        File    otu_ref
        File    taxanomy_ref
        String  forward_adapter
        String  reverse_adapter
        Int    min_length  =   100
        Int    max_length  =   500
        String  otu_basename    =   basename(otu_ref, '.qza')
        String  docker = "quay.io/qiime2/core:2022.8"
    }
    command <<<
    set -ex -o pipefail
        # obtain the name of the qiime conda environment in the container; flexible about version
        CONDA_ENV_NAME=$(conda info --envs -q | awk -F" " '/qiime.*/{ print $1 }')
        # activate the qiime conda environment
        # seemingly necessary because of:
        #   https://github.com/chanzuckerberg/miniwdl/issues/603
        conda activate ${CONDA_ENV_NAME}
        
        #is this otu different than the one above? or is it the rep-seqs outifle?
        #is this how you specify a path?
        qiime tools import \
        --type 'FeatureData[Sequence]' \
        --input-path ~{otu_ref} \
        --output-path "~{otu_basename}_seqs.qza"

        #is this db different than the one above?
        qiime tools import \
        --type 'FeatureData[Taxonomy]'
        --input-format HeaderlessTSVTaxonomyFormat \
        --input-path ~{taxanomy_ref} \
        --output-path "~_v{otu_basename}_tax.qza"

        qiime feature-classifier extract-reads\
        --i-sequeunces "~{otu_basename}_seqs.qza"\
        --p-f-primer "~{forward_adapter}"\
        --p-r-primer "~{reverse_adapter}"\
        ~{"--p-min_length" + min_length}\
        ~{"--p-max_length" + max_length}\
        --o-reads "~{otu_basename}_v1_2_ref_seqs.qza"
#might have to be broken down into two tasks
        qiime feature-classifier fit-classifier-naive-bayes\ 
        --i-reference-reads "~{otu_basename}_v1_2_ref_seqs.qza"\ 
        --i-reference-taxonomy "~{otu_basename}_tax.qza"\ 
        --o-classifier "~{otu_basename}_v1_2_classifier.qza"
    >>>
    output {
        File    trained_classifier = "~{otu_basename}_v1_2_classifier.qza"
    }
    runtime {
        docker: "~{docker}"
        memory: "10 GB"
        cpu: 1
    }

}
task tax_analysis {
    meta {
        description: "Protocol describes performing a taxonomic classification with a naive bayes classifier that has been trained on the V1-2 regions amplified by our primers."
    }
    input {
        File trained_classifier
        File rep_seqs_outfile
        File rep_table_outfile 
        String  basename  =   basename(trained_classifier, '.qza')
        String  docker = "quay.io/qiime2/core:2022.8"
    }
    command <<<
        set -ex -o pipefail
        # obtain the name of the qiime conda environment in the container; flexible about version
        CONDA_ENV_NAME=$(conda info --envs -q | awk -F" " '/qiime.*/{ print $1 }')
        # activate the qiime conda environment
        # seemingly necessary because of:
        #   https://github.com/chanzuckerberg/miniwdl/issues/603
        conda activate ${CONDA_ENV_NAME}
        
        qiime feature-classifier classify-sklearn \
        --i-classifier ~{trained_classifier} \
        --i-reads ~{rep_seqs_outfile} \
        --o-classification "~{basename}_tax.qza"
        
        qiime feature-table tabulate-seqs \
        --i-data ~{rep_seqs_outfile} \
        --o-visualization "~{basename}_rep_seqs.qzv"

        qiime taxa barplot \
        --i-table ~{rep_table_outfile} \
        --i-taxonomy "~{basename}_tax.qza" \
        --o-visualization "~{basename}_bar_plots.qzv"
    >>>
    output {
        File rep_seq_list = "~{basename}_rep_seqs.qzv" 
        File tax_classification_graph = "~{basename}_bar_plots.qzv"
    }
    runtime {
        docker: "~{docker}"
        memory: "10 GB"
        cpu: 1
    }
}
# One caviat is that you need to visualize the bar plot using qiime2.org 