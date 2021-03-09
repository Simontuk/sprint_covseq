#! /usr/bin/env nextflow
/* 
nextflow pipeline for cov-seq analysis in the Sprint project
*/
// TODO: help message
def helpMessage() {
    "usage documentation"
}

// :

// Adapted from nf-core/viralrecon

// Show help message
if (params.help) {
    helpMessage()
    exit 0
}

// Has the run name been specified by the user?
// this has the bonus effect of catching both -name and --name
custom_runName = params.name
if (!(workflow.runName ==~ /[a-z]+_[a-z]+/)) {
    custom_runName = workflow.runName
}

////////////////////////////////////////////////////
/* --          VALIDATE INPUTS                 -- */
////////////////////////////////////////////////////

if (params.input) { ch_input = file(params.input, checkIfExists: true) } else { exit 1, "Input samplesheet file not specified!" }

if (params.protocol != 'metagenomic' && params.protocol != 'amplicon') {
    exit 1, "Invalid protocol option: ${params.protocol}. Valid options: 'metagenomic' or 'amplicon'!"
}

if (params.protocol == 'amplicon' && !params.skip_assembly && !params.amplicon_fasta) {
    exit 1, "To perform de novo assembly in 'amplicon' mode please provide a valid amplicon fasta file!"
}
if (params.amplicon_fasta) { ch_amplicon_fasta = file(params.amplicon_fasta, checkIfExists: true) }

if (params.protocol == 'amplicon' && !params.skip_variants && !params.amplicon_bed) {
    exit 1, "To perform variant calling in 'amplicon' mode please provide a valid amplicon BED file!"
}
if (params.amplicon_bed) { ch_amplicon_bed = file(params.amplicon_bed, checkIfExists: true) }

callerList = [ 'varscan2', 'ivar', 'bcftools']
callers = params.callers ? params.callers.split(',').collect{ it.trim().toLowerCase() } : []
if ((callerList + callers).unique().size() != callerList.size()) {
    exit 1, "Invalid variant calller option: ${params.callers}. Valid options: ${callerList.join(', ')}"
}

assemblerList = [ 'spades', 'metaspades', 'unicycler', 'minia' ]
assemblers = params.assemblers ? params.assemblers.split(',').collect{ it.trim().toLowerCase() } : []
if ((assemblerList + assemblers).unique().size() != assemblerList.size()) {
    exit 1, "Invalid assembler option: ${params.assemblers}. Valid options: ${assemblerList.join(', ')}"
}

// Viral reference files
if (params.genomes && params.genome && !params.genomes.containsKey(params.genome)) {
   exit 1, "The provided genome '${params.genome}' is not available in the Genome file. Currently the available genomes are ${params.genomes.keySet().join(", ")}"
}
params.fasta = params.genome ? params.genomes[ params.genome ].fasta ?: false : false
params.gff = params.genome ? params.genomes[ params.genome ].gff ?: false : false

if (params.fasta) {
    file(params.fasta, checkIfExists: true)

    lastPath = params.fasta.lastIndexOf(File.separator)
    lastExt = params.fasta.lastIndexOf(".")
    fasta_base = params.fasta.substring(lastPath+1)
    index_base = params.fasta.substring(lastPath+1,lastExt)
    if (params.fasta.endsWith('.gz')) {
        fasta_base = params.fasta.substring(lastPath+1,lastExt)
        index_base = fasta_base.substring(0,fasta_base.lastIndexOf("."))
    }
} else {
    exit 1, "Viral genome fasta file not specified!"
}

////////////////////////////////////////////////////
/* --          CONFIG FILES                    -- */
////////////////////////////////////////////////////

ch_multiqc_config = file("$baseDir/assets/multiqc_config.yaml", checkIfExists: true)
ch_multiqc_custom_config = params.multiqc_config ? Channel.fromPath(params.multiqc_config, checkIfExists: true) : Channel.empty()
ch_output_docs = file("$baseDir/docs/output.md", checkIfExists: true)
ch_output_docs_images = file("$baseDir/docs/images/", checkIfExists: true)

////////////////////////////////////////////////////
/* --          HEADER FILES                    -- */
////////////////////////////////////////////////////

ch_blast_outfmt6_header = file("$baseDir/assets/headers/blast_outfmt6_header.txt", checkIfExists: true)
ch_ivar_variants_header_mqc = file("$baseDir/assets/headers/ivar_variants_header_mqc.txt", checkIfExists: true)

////////////////////////////////////////////////////
/* --                   AWS                    -- */
////////////////////////////////////////////////////

// Check AWS batch settings
if (workflow.profile.contains('awsbatch')) {
    // AWSBatch sanity checking
    if (!params.awsqueue || !params.awsregion) exit 1, "Specify correct --awsqueue and --awsregion parameters on AWSBatch!"
    // Check outdir paths to be S3 buckets if running on AWSBatch
    // related: https://github.com/nextflow-io/nextflow/issues/813
    if (!params.outdir.startsWith('s3:')) exit 1, "Outdir not on S3 - specify S3 Bucket to run on AWSBatch!"
    // Prevent trace files to be stored on S3 since S3 does not support rolling files.
    if (params.tracedir.startsWith('s3:')) exit 1, "Specify a local tracedir or run without trace! S3 cannot be used for tracefiles."
}

///////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////
/* --                                                                     -- */
/* --                       HEADER LOG INFO                               -- */
/* --                                                                     -- */
///////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////

// Header log info
log.info nfcoreHeader()
def summary = [:]
if (workflow.revision)               summary['Pipeline Release'] = workflow.revision
summary['Run Name']                  = custom_runName ?: workflow.runName
summary['Samplesheet']               = params.input
summary['Protocol']                  = params.protocol
if (params.protocol == 'amplicon')   summary['Amplicon Fasta File'] = params.amplicon_fasta
if (params.protocol == 'amplicon')   summary['Amplicon BED File'] = params.amplicon_bed
if (params.protocol == 'amplicon')   summary['Amplicon Left Suffix'] = params.amplicon_left_suffix
if (params.protocol == 'amplicon')   summary['Amplicon Right Suffix'] = params.amplicon_right_suffix
summary['Viral Genome']              = params.genome ?: 'Not supplied'
summary['Viral Fasta File']          = params.fasta
if (params.gff)                      summary['Viral GFF'] = params.gff
if (params.save_reference)           summary['Save Genome Indices'] = 'Yes'
if (params.save_sra_fastq)           summary['Save SRA FastQ'] = params.save_sra_fastq
if (params.skip_sra)                 summary['Skip SRA Download'] = params.skip_sra
if (!params.skip_adapter_trimming)  {
    if (params.cut_mean_quality)          summary['Fastp Mean Qual'] = params.cut_mean_quality
    if (params.qualified_quality_phred)   summary['Fastp Qual Phred'] = params.qualified_quality_phred
    if (params.unqualified_percent_limit) summary['Fastp Unqual % Limit'] = params.unqualified_percent_limit
    if (params.min_trim_length)           summary['Fastp Min Trim Length'] = params.min_trim_length
} else {
    summary['Skip Adapter Trimming'] = 'Yes'
}
if (params.skip_amplicon_trimming)   summary['Skip Amplicon Trimming'] = 'Yes'
if (params.save_trimmed)             summary['Save Trimmed'] = 'Yes'
if (!params.skip_variants) {
    summary['Variant Calling Tools'] = params.callers
    summary['Min Mapped Reads']      = params.min_mapped_reads
    if (params.ivar_trim_noprimer)   summary['iVar Trim Exclude']  = 'Yes'
    summary['iVar Trim Min Len']     = params.ivar_trim_min_len
    summary['iVar Trim Min Qual']    = params.ivar_trim_min_qual
    summary['iVar Trim Window']      = params.ivar_trim_window_width
    if (params.filter_dups)          summary['Remove Duplicate Reads']  = 'Yes'
    if (params.filter_unmapped)      summary['Remove Unmapped Reads']  = 'Yes'
    summary['Mpileup Depth']         = params.mpileup_depth
    summary['Min Base Quality']      = params.min_base_qual
    summary['Min Read Depth']        = params.min_coverage
    summary['Min Allele Freq']       = params.min_allele_freq
    summary['Max Allele Freq']       = params.max_allele_freq
    if (params.varscan2_strand_filter) summary['Varscan2 Strand Filter'] = 'Yes'
    if (params.save_align_intermeds) summary['Save Align Intermeds'] =  'Yes'
    if (params.save_mpileup)         summary['Save mpileup'] = 'Yes'
    if (params.skip_markduplicates)  summary['Skip MarkDuplicates'] = 'Yes'
    if (params.skip_picard_metrics)  summary['Skip Picard Metrics'] = 'Yes'
    if (params.skip_mosdepth)        summary['Skip mosdepth'] = 'Yes'
    if (params.skip_snpeff)          summary['Skip SnpEff'] = 'Yes'
    if (params.skip_variants_quast)  summary['Skip Variants QUAST'] = 'Yes'
} else {
    summary['Skip Variant Calling']  = 'Yes'
}
if (!params.skip_kraken2 && !params.skip_assembly) {
    if (params.kraken2_db)           summary['Host Kraken2 DB'] = params.kraken2_db
    if (params.kraken2_db_name)      summary['Host Kraken2 Name'] = params.kraken2_db_name
    if (params.kraken2_use_ftp)      summary['Kraken2 Use FTP'] = params.kraken2_use_ftp
    if (params.save_kraken2_fastq)   summary['Save Kraken2 FastQ'] = params.save_kraken2_fastq
} else {
    summary['Skip Kraken2']          = 'Yes'
}
if (!params.skip_assembly) {
    summary['Assembly Tools']        = params.assemblers
    summary['Minia Kmer Size']       = params.minia_kmer
    if (params.skip_vg)              summary['Skip Variant Graph'] =  'Yes'
    if (params.skip_blast)           summary['Skip BLAST'] =  'Yes'
    if (params.skip_abacas)          summary['Skip ABACAS'] =  'Yes'
    if (params.skip_plasmidid)       summary['Skip PlasmidID'] =  'Yes'
    if (params.skip_assembly_quast)  summary['Skip Assembly QUAST'] =  'Yes'
} else {
    summary['Skip Assembly']         = 'Yes'
}
if (params.skip_fastqc)              summary['Skip FastQC'] = 'Yes'
if (params.skip_multiqc)             summary['Skip MultiQC'] = 'Yes'
summary['Max Resources']             = "$params.max_memory memory, $params.max_cpus cpus, $params.max_time time per job"
if (workflow.containerEngine)        summary['Container'] = "$workflow.containerEngine - $workflow.container"
summary['Output dir']                = params.outdir
summary['Publish dir mode']          = params.publish_dir_mode
summary['Launch dir']                = workflow.launchDir
summary['Working dir']               = workflow.workDir
summary['Script dir']                = workflow.projectDir
summary['User']                      = workflow.userName
if (workflow.profile.contains('awsbatch')) {
    summary['AWS Region']            = params.awsregion
    summary['AWS Queue']             = params.awsqueue
    summary['AWS CLI']               = params.awscli
}
summary['Config Profile']            = workflow.profile
if (params.config_profile_description) summary['Config Description'] = params.config_profile_description
if (params.config_profile_contact)     summary['Config Contact']     = params.config_profile_contact
if (params.config_profile_url)         summary['Config URL']         = params.config_profile_url
if (params.email || params.email_on_fail) {
    summary['E-mail Address']        = params.email
    summary['E-mail on failure']     = params.email_on_fail
    summary['MultiQC maxsize']       = params.max_multiqc_email_size
}
log.info summary.collect { k,v -> "${k.padRight(22)}: $v" }.join("\n")
log.info "-\033[2m--------------------------------------------------\033[0m-"

// Check the hostnames against configured profiles
checkHostname()

///////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////
/* --                                                                     -- */
/* --                 UNZIP/UNTAR REFERENCE FILES                         -- */
/* --                                                                     -- */
///////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////

/*
 * PREPROCESSING: Uncompress genome fasta file
 */
if (params.fasta.endsWith('.gz')) {
    process GUNZIP_FASTA {
        label 'error_retry'
        if (params.save_reference) {
            publishDir "${params.outdir}/genome", mode: params.publish_dir_mode
        }

        input:
        path fasta from params.fasta

        output:
        path "$unzip" into ch_fasta

        script:
        unzip = fasta.toString() - '.gz'
        """
        pigz -f -d -p $task.cpus $fasta
        """
    }
} else {
    ch_fasta = file(params.fasta)
}

// Print warning if viral genome fasta has more than one sequence
def count = 0
ch_fasta.withReader { reader ->
    while (line = reader.readLine()) {
        if (line.contains('>')) {
            count++
            if (count > 1) {
                log.info "[nf-core/viralrecon] WARNING: This pipeline does not support multi-fasta genome files. Please amend the '--fasta' parameter."
                break
            }
        }
    }
}

/*
 * PREPROCESSING: Uncompress gff annotation file
 */
if (params.gff) {
    file(params.gff, checkIfExists: true)
    if (params.gff.endsWith('.gz')) {
        process GUNZIP_GFF {
            label 'error_retry'
            if (params.save_reference) {
                publishDir "${params.outdir}/genome", mode: params.publish_dir_mode
            }

            input:
            path gff from params.gff

            output:
            path "$unzip" into ch_gff

            script:
            unzip = gff.toString() - '.gz'
            """
            pigz -f -d -p $task.cpus $gff
            """
        }
    } else {
        ch_gff = file(params.gff)
    }
} else {
    //See: https://nextflow-io.github.io/patterns/index.html#_optional_input
    ch_gff = file('NO_FILE')
}

/*
 * PREPROCESSING: Uncompress Kraken2 database
 */
if (!params.skip_kraken2 && params.kraken2_db && !params.skip_assembly) {
    file(params.kraken2_db, checkIfExists: true)
    if (params.kraken2_db.endsWith('.tar.gz')) {
        process UNTAR_KRAKEN2_DB {
            label 'error_retry'
            if (params.save_reference) {
                publishDir "${params.outdir}/genome", mode: params.publish_dir_mode
            }

            input:
            path db from params.kraken2_db

            output:
            path "$untar" into ch_kraken2_db

            script:
            untar = db.toString() - '.tar.gz'
            """
            tar -xvf $db
            """
        }
    } else {
        ch_kraken2_db = file(params.kraken2_db)
    }
}


///////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////
/* --                                                                     -- */
/* --                     PARSE DESIGN FILE                               -- */
/* --                                                                     -- */
///////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////

/*
 * PREPROCESSING: Reformat samplesheet and check validity
 */

process CHECK_SAMPLESHEET {
    tag "$samplesheet"
    publishDir "${params.outdir}/", mode: params.publish_dir_mode,
        saveAs: { filename ->
                      if (filename.endsWith(".tsv")) "preprocess/sra/$filename"
                      else "pipeline_info/$filename"
                }

    input:
    path samplesheet from ch_input

    output:
    path "samplesheet.valid.csv" into ch_samplesheet_reformat
    path "sra_run_info.tsv" optional true

    script:  // These scripts are bundled with the pipeline, in nf-core/viralrecon/bin/
    run_sra = !params.skip_sra && !isOffline()
    """
    awk -F, '{if(\$1 != "" && \$2 != "") {print \$0}}' $samplesheet > nonsra_id.csv
    check_samplesheet.py nonsra_id.csv nonsra.samplesheet.csv

    awk -F, '{if(\$1 != "" && \$2 == "" && \$3 == "") {print \$1}}' $samplesheet > sra_id.list
    if $run_sra && [ -s sra_id.list ]
    then
        fetch_sra_runinfo.py sra_id.list sra_run_info.tsv --platform ILLUMINA --library_layout SINGLE,PAIRED
        sra_runinfo_to_samplesheet.py sra_run_info.tsv sra.samplesheet.csv
    fi

    if [ -f nonsra.samplesheet.csv ]
    then
        head -n 1 nonsra.samplesheet.csv > samplesheet.valid.csv
    else
        head -n 1 sra.samplesheet.csv > samplesheet.valid.csv
    fi
    tail -n +2 -q *sra.samplesheet.csv >> samplesheet.valid.csv
    """
}



// Function to get list of [ sample, single_end?, is_sra?, is_ftp?, [ fastq_1, fastq_2 ], [ md5_1, md5_2] ]
def validate_input(LinkedHashMap sample) {
    def sample_id = sample.sample_id
    def single_end = sample.single_end.toBoolean()
    def is_sra = sample.is_sra.toBoolean()
    def is_ftp = sample.is_ftp.toBoolean()
    def fastq_1 = sample.fastq_1
    def fastq_2 = sample.fastq_2
    def md5_1 = sample.md5_1
    def md5_2 = sample.md5_2

    def array = []
    if (!is_sra) {
        if (single_end) {
            array = [ sample_id, single_end, is_sra, is_ftp, [ file(fastq_1, checkIfExists: true) ] ]
        } else {
            array = [ sample_id, single_end, is_sra, is_ftp, [ file(fastq_1, checkIfExists: true), file(fastq_2, checkIfExists: true) ] ]
        }
    } else {
        array = [ sample_id, single_end, is_sra, is_ftp, [ fastq_1, fastq_2 ], [ md5_1, md5_2 ] ]
    }

    return array
}


/*
 * Create channels for input fastq files
 */
ch_samplesheet_reformat
    .splitCsv(header:true, sep:',')
    .map { validate_input(it) }
    .into { ch_reads_all
            ch_reads_sra }


ch_reads_all
    .map { [ it[0].split('_')[0..-2].join('_'), it[1], it[4] ] }
    .groupTuple(by: [0, 1])
    .map { [ it[0], it[1], it[2].flatten() ] }
    .set { ch_reads_all }



/*
 * STEP 2: Merge FastQ files with the same sample identifier
 */
process CAT_FASTQ {
    tag "$sample"

    input:
    tuple val(sample), val(single_end), path(reads) from ch_reads_all

    output:
    tuple val(sample), val(single_end), path("*.merged.fastq.gz") into ch_cat_fastqc,
                                                                       ch_cat_fastp

    script:
    readList = reads.collect{it.toString()}
    if (!single_end) {
        if (readList.size > 2) {
            def read1 = []
            def read2 = []
            readList.eachWithIndex{ v, ix -> ( ix & 1 ? read2 : read1 ) << v }
            """
            cat ${read1.sort().join(' ')} > ${sample}_1.merged.fastq.gz
            cat ${read2.sort().join(' ')} > ${sample}_2.merged.fastq.gz
            """
        } else {
            """
            ln -s ${reads[0]} ${sample}_1.merged.fastq.gz
            ln -s ${reads[1]} ${sample}_2.merged.fastq.gz
            """
        }
    } else {
        if (readList.size > 1) {
            """
            cat ${readList.sort().join(' ')} > ${sample}.merged.fastq.gz
            """
        } else {
            """
            ln -s $reads ${sample}.merged.fastq.gz
            """
        }
    }
}

///////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////
/* --                                                                     -- */
/* --                        FASTQ QC                                     -- */
/* --                                                                     -- */
///////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////

/*
 * STEP 3: FastQC on input reads after merging libraries from the same sample
 */
process FASTQC {
    tag "$sample"
    label 'process_medium'
    publishDir "${params.outdir}/preprocess/fastqc", mode: params.publish_dir_mode,
        saveAs: { filename ->
                      filename.endsWith(".zip") ? "zips/$filename" : filename
                }

    when:
    !params.skip_fastqc

    input:
    tuple val(sample), val(single_end), path(reads) from ch_cat_fastqc

    output:
    path "*.{zip,html}" into ch_fastqc_raw_reports_mqc

    script:
    """
    fastqc --quiet --threads $task.cpus *.fastq.gz
    """
}



///////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////
/* --                                                                     -- */
/* --                        ADAPTER TRIMMING                             -- */
/* --                                                                     -- */
///////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////

/*
 * STEP 4: Fastp adapter trimming and quality filtering
 */
if (!params.skip_adapter_trimming) {
    process FASTP {
        tag "$sample"
        label 'process_medium'
        publishDir "${params.outdir}/preprocess/fastp", mode: params.publish_dir_mode,
            saveAs: { filename ->
                          if (filename.endsWith(".json")) filename
                          else if (filename.endsWith(".fastp.html")) filename
                          else if (filename.endsWith("_fastqc.html")) "fastqc/$filename"
                          else if (filename.endsWith(".zip")) "fastqc/zips/$filename"
                          else if (filename.endsWith(".log")) "log/$filename"
                          else params.save_trimmed ? filename : null
                    }

        when:
        !params.skip_variants || !params.skip_assembly

        input:
        tuple val(sample), val(single_end), path(reads) from ch_cat_fastp

        output:
        tuple val(sample), val(single_end), path("*.trim.fastq.gz") into ch_fastp_kraken2
        path "*.json" into ch_fastp_mqc
        path "*_fastqc.{zip,html}" into ch_fastp_fastqc_mqc
        path "*.{log,fastp.html}"
        path "*.fail.fastq.gz"

        script:
        // Added soft-links to original fastqs for consistent naming in MultiQC
        autodetect = single_end ? "" : "--detect_adapter_for_pe"
        """
        IN_READS='--in1 ${sample}.fastq.gz'
        OUT_READS='--out1 ${sample}.trim.fastq.gz --failed_out ${sample}.fail.fastq.gz'
        if $single_end; then
            [ ! -f  ${sample}.fastq.gz ] && ln -s $reads ${sample}.fastq.gz
        else
            [ ! -f  ${sample}_1.fastq.gz ] && ln -s ${reads[0]} ${sample}_1.fastq.gz
            [ ! -f  ${sample}_2.fastq.gz ] && ln -s ${reads[1]} ${sample}_2.fastq.gz
            IN_READS='--in1 ${sample}_1.fastq.gz --in2 ${sample}_2.fastq.gz'
            OUT_READS='--out1 ${sample}_1.trim.fastq.gz --out2 ${sample}_2.trim.fastq.gz --unpaired1 ${sample}_1.fail.fastq.gz --unpaired2 ${sample}_2.fail.fastq.gz'
        fi

        fastp \\
            \$IN_READS \\
            \$OUT_READS \\
            $autodetect \\
            --cut_front \\
            --cut_tail \\
            --cut_mean_quality $params.cut_mean_quality \\
            --qualified_quality_phred $params.qualified_quality_phred \\
            --unqualified_percent_limit $params.unqualified_percent_limit \\
            --length_required $params.min_trim_length \\
            --trim_poly_x \\
            --thread $task.cpus \\
            --json ${sample}.fastp.json \\
            --html ${sample}.fastp.html \\
            2> ${sample}.fastp.log

        fastqc --quiet --threads $task.cpus *.trim.fastq.gz
        """
    }
} else {
    ch_cat_fastp
        .into { ch_fastp_kraken2 }
    ch_fastp_mqc = Channel.empty()
    ch_fastp_fastqc_mqc = Channel.empty()
}



///////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////
/* --                                                                     -- */
/* --                        KRAKEN Human read removal                    -- */
/* --                                                                     -- */
///////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////


/*
 * PREPROCESSING: Build Kraken2 database for host genome
 */
if (!isOffline()) {
    if (!params.skip_kraken2 && !params.kraken2_db) {
        if (!params.kraken2_db_name) { exit 1, "Please specify a valid name to build Kraken2 database for host e.g. 'human'!" }

        process KRAKEN2_BUILD {
            tag "$db"
            label 'process_high'
            if (params.save_reference) {
                publishDir "${params.outdir}/genome", mode: params.publish_dir_mode
            }

            when:
            !params.skip_assembly

            output:
            path "$db" into ch_kraken2_db

            script:
            db = "kraken2_${params.kraken2_db_name}"
            ftp = params.kraken2_use_ftp ? "--use-ftp" : ""
            """
            kraken2-build --db $db --threads $task.cpus $ftp --download-taxonomy
            kraken2-build --db $db --threads $task.cpus $ftp --download-library $params.kraken2_db_name
            kraken2-build --db $db --threads $task.cpus $ftp --build
            """
        }
    }
} else {
    exit 1, "NXF_OFFLINE=true or -offline has been set so cannot download files required to build Kraken2 database!"
}



/*
 * STEP 4.1: Filter reads with Kraken2
 */
if (!params.skip_kraken2) {
    process KRAKEN2 {
        tag "$db"
        label 'process_high'
        publishDir "${params.outdir}/assembly/kraken2", mode: params.publish_dir_mode,
            saveAs: { filename ->
                          if (filename.endsWith(".txt")) filename
                          else params.save_kraken2_fastq ? filename : null
                    }

        input:
        tuple val(sample), val(single_end), path(reads) from ch_fastp_kraken2
        path db from ch_kraken2_db

        output:
        tuple val(sample), val(single_end), path("*.viral*") into ch_fastp_bowtie2
        path "*.report.txt" into ch_kraken2_report_mqc
        path "*.host*"


        script:
        pe = single_end ? "" : "--paired"
        classified = single_end ? "${sample}.host.fastq" : "${sample}.host#.fastq"
        unclassified = single_end ? "${sample}.viral.fastq" : "${sample}.viral#.fastq"
        """
        kraken2 \\
            --db $db \\
            --threads $task.cpus \\
            --unclassified-out $unclassified \\
            --classified-out $classified \\
            --report ${sample}.kraken2.report.txt \\
            --report-zero-counts \\
            $pe \\
            --gzip-compressed \\
            $reads
        pigz -p $task.cpus *.fastq
        """
    }
} else {
    ch_fastp_kraken2
        .into { ch_fastp_bowtie2 }
    ch_kraken2_report_mqc = Channel.empty()
}

///////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////
/* --                                                                     -- */
/* --                  VARIANT CALLING PROCESSES                          -- */
/* --                                                                     -- */
///////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////

/*
 * PREPROCESSING: Build Bowtie2 index for viral genome
 */
process BOWTIE2_INDEX {
    tag "$fasta"
    label 'process_medium'
    if (params.save_reference) {
        publishDir "${params.outdir}/genome", mode: params.publish_dir_mode
    }

    when:
    !params.skip_variants

    input:
    path fasta from ch_fasta

    output:
    path "Bowtie2Index" into ch_index

    script:
    """
    bowtie2-build \\
        --seed 1 \\
        --threads $task.cpus \\
        $fasta \\
        $index_base
    mkdir Bowtie2Index && mv ${index_base}* Bowtie2Index
    """
}

/*
 * PREPROCESSING: Build SnpEff database for viral genome
 */
process MAKE_SNPEFF_DB {
    tag "${index_base}.fa"
    label 'process_low'
    if (params.save_reference) {
        publishDir "${params.outdir}/genome", mode: params.publish_dir_mode
    }

    when:
    (!params.skip_variants || !params.skip_assembly) && params.gff && !params.skip_snpeff

    input:
    path ("SnpEffDB/genomes/${index_base}.fa") from ch_fasta
    path ("SnpEffDB/${index_base}/genes.gff") from ch_gff

    output:
    tuple path("SnpEffDB"), path("*.config") into ch_snpeff_db_varscan2,
                                                  ch_snpeff_db_ivar,
                                                  ch_snpeff_db_bcftools,
                                                  ch_snpeff_db_spades,
                                                  ch_snpeff_db_metaspades,
                                                  ch_snpeff_db_unicycler,
                                                  ch_snpeff_db_minia

    script:
    """
    echo "${index_base}.genome : ${index_base}" > snpeff.config
    snpEff build -config snpeff.config -dataDir ./SnpEffDB -gff3 -v ${index_base}
    """
}

/*
 * STEP 5.1: Map read(s) with Bowtie 2
 */
process BOWTIE2 {
    tag "$sample"
    label 'process_medium'
    publishDir "${params.outdir}/variants/bam", mode: params.publish_dir_mode,
        saveAs: { filename ->
                      if (filename.endsWith(".log")) "log/$filename"
                      else params.save_align_intermeds ? filename : null
                }

    when:
    !params.skip_variants

    input:
    tuple val(sample), val(single_end), path(reads) from ch_fastp_bowtie2
    path index from ch_index

    output:
    tuple val(sample), val(single_end), path("*.bam") into ch_bowtie2_bam
    path "*.log" into ch_bowtie2_mqc

    script:
    input_reads = single_end ? "-U $reads" : "-1 ${reads[0]} -2 ${reads[1]}"
    filter = params.filter_unmapped ? "-F4" : ""
    """
    bowtie2 \\
        --threads $task.cpus \\
        --local \\
        --very-sensitive-local \\
        -x ${index}/${index_base} \\
        $input_reads \\
        2> ${sample}.bowtie2.log \\
        | samtools view -@ $task.cpus -b -h -O BAM -o ${sample}.bam $filter -
    """
}

/*
 * STEP 5.2: Convert BAM to coordinate sorted BAM
 */
process SORT_BAM {
    tag "$sample"
    label 'process_medium'
    publishDir "${params.outdir}/variants/bam", mode: params.publish_dir_mode,
        saveAs: { filename ->
                      if (filename.endsWith(".flagstat")) "samtools_stats/$filename"
                      else if (filename.endsWith(".idxstats")) "samtools_stats/$filename"
                      else if (filename.endsWith(".stats")) "samtools_stats/$filename"
                      else (params.protocol != 'amplicon' && params.skip_markduplicates) || params.save_align_intermeds ? filename : null
                }

    when:
    !params.skip_variants

    input:
    tuple val(sample), val(single_end), path(bam) from ch_bowtie2_bam

    output:
    tuple val(sample), val(single_end), path("*.sorted.{bam,bam.bai}"), path("*.flagstat") into ch_sort_bam
    path "*.{flagstat,idxstats,stats}" into ch_sort_bam_flagstat_mqc

    script:
    """
    samtools sort -@ $task.cpus -o ${sample}.sorted.bam -T $sample $bam
    samtools index ${sample}.sorted.bam
    samtools flagstat ${sample}.sorted.bam > ${sample}.sorted.bam.flagstat
    samtools idxstats ${sample}.sorted.bam > ${sample}.sorted.bam.idxstats
    samtools stats ${sample}.sorted.bam > ${sample}.sorted.bam.stats
    """
}

// Get total number of mapped reads from flagstat file
def get_mapped_from_flagstat(flagstat) {
    def mapped = 0
    flagstat.eachLine { line ->
        if (line.contains(' mapped (')) {
            mapped = line.tokenize().first().toInteger()
        }
    }
    return mapped
}

// Function that checks the number of mapped reads from flagstat output
// and returns true if > params.min_mapped_reads and otherwise false
pass_mapped_reads = [:]
fail_mapped_reads = [:]
def check_mapped(sample,flagstat,min_mapped_reads=500) {
    mapped = get_mapped_from_flagstat(flagstat)
    c_reset = params.monochrome_logs ? '' : "\033[0m";
    c_green = params.monochrome_logs ? '' : "\033[0;32m";
    c_red = params.monochrome_logs ? '' : "\033[0;31m";
    if (mapped < min_mapped_reads.toInteger()) {
        log.info ">${c_red}>>>> $sample FAILED MAPPED READ THRESHOLD: ${mapped} < ${params.min_mapped_reads}. IGNORING FOR FURTHER DOWNSTREAM ANALYSIS! <<<<${c_reset}<"
        fail_mapped_reads[sample] = mapped
        return false
    } else {
        //log.info "-${c_green}           Passed mapped read threshold > bowtie2 ($sample)   >> ${mapped} <<${c_reset}"
        pass_mapped_reads[sample] = mapped
        return true
    }
}

// Remove samples that failed mapped read threshold
ch_sort_bam
    .filter { sample, single_end, bam, flagstat -> check_mapped(sample,flagstat,params.min_mapped_reads) }
    .map { it[0..2] }
    .set { ch_sort_bam }



/*
 * STEP 5.3: Trim amplicon sequences with iVar
 */
if (params.protocol != 'amplicon') {
    ch_sort_bam
        .set { ch_ivar_trim_bam }
    ch_ivar_trim_flagstat_mqc = Channel.empty()
    ch_ivar_trim_log_mqc = Channel.empty()
} else {
    process IVAR_TRIM {
        tag "$sample"
        label 'process_medium'
        publishDir "${params.outdir}/variants/bam", mode: params.publish_dir_mode,
            saveAs: { filename ->
                          if (filename.endsWith(".flagstat")) "samtools_stats/$filename"
                          else if (filename.endsWith(".idxstats")) "samtools_stats/$filename"
                          else if (filename.endsWith(".stats")) "samtools_stats/$filename"
                          else if (filename.endsWith(".log")) "log/$filename"
                          else params.skip_markduplicates || params.save_align_intermeds ? filename : null
                    }

        when:
        !params.skip_variants

        input:
        tuple val(sample), val(single_end), path(bam) from ch_sort_bam
        path bed from ch_amplicon_bed

        output:
        tuple val(sample), val(single_end), path("*.sorted.{bam,bam.bai}") into ch_ivar_trim_bam
        path "*.{flagstat,idxstats,stats}" into ch_ivar_trim_flagstat_mqc
        path "*.log" into ch_ivar_trim_log_mqc

        script:
        exclude_reads = params.ivar_trim_noprimer ? "" : "-e"
        prefix = "${sample}.trim"
        """
        samtools view -b -F 4 ${bam[0]} > ${sample}.mapped.bam
        samtools index ${sample}.mapped.bam

        ivar trim \\
            -i ${sample}.mapped.bam \\
            -b $bed \\
            -m $params.ivar_trim_min_len \\
            -q $params.ivar_trim_min_qual \\
            -s $params.ivar_trim_window_width \\
            $exclude_reads \\
            -p $prefix > ${prefix}.ivar.log

        samtools sort -@ $task.cpus -o ${prefix}.sorted.bam -T $prefix ${prefix}.bam
        samtools index ${prefix}.sorted.bam
        samtools flagstat ${prefix}.sorted.bam > ${prefix}.sorted.bam.flagstat
        samtools idxstats ${prefix}.sorted.bam > ${prefix}.sorted.bam.idxstats
        samtools stats ${prefix}.sorted.bam > ${prefix}.sorted.bam.stats
        """
    }
}

/*
 * STEP 5.4: Picard MarkDuplicates
 */
if (params.skip_markduplicates) {
    ch_ivar_trim_bam
        .into { ch_markdup_bam_metrics
                ch_markdup_bam_mosdepth_genome
                ch_markdup_bam_mosdepth_amplicon
                ch_markdup_bam_mpileup
                ch_markdup_bam_varscan2_consensus
                ch_markdup_bam_bcftools
                ch_markdup_bam_bcftools_consensus }
    ch_markdup_bam_flagstat_mqc = Channel.empty()
    ch_markdup_bam_metrics_mqc = Channel.empty()
} else {
    process PICARD_MARKDUPLICATES {
        tag "$sample"
        label 'process_medium'
        publishDir "${params.outdir}/variants/bam", mode: params.publish_dir_mode,
            saveAs: { filename ->
                          if (filename.endsWith(".flagstat")) "samtools_stats/$filename"
                          else if (filename.endsWith(".idxstats")) "samtools_stats/$filename"
                          else if (filename.endsWith(".stats")) "samtools_stats/$filename"
                          else if (filename.endsWith(".metrics.txt")) "picard_metrics/$filename"
                          else filename
                    }

        when:
        !params.skip_variants

        input:
        tuple val(sample), val(single_end), path(bam) from ch_ivar_trim_bam
        path fasta from ch_fasta

        output:
        tuple val(sample), val(single_end), path("*.sorted.{bam,bam.bai}") into ch_markdup_bam_metrics,
                                                                                ch_markdup_bam_mosdepth_genome,
                                                                                ch_markdup_bam_mosdepth_amplicon,
                                                                                ch_markdup_bam_mpileup,
                                                                                ch_markdup_bam_varscan2_consensus,
                                                                                ch_markdup_bam_bcftools,
                                                                                ch_markdup_bam_bcftools_consensus
        path "*.{flagstat,idxstats,stats}" into ch_markdup_bam_flagstat_mqc
        path "*.txt" into ch_markdup_bam_metrics_mqc

        script:
        def avail_mem = 3
        if (!task.memory) {
            log.info "[Picard MarkDuplicates] Available memory not known - defaulting to 3GB. Specify process memory requirements to change this."
        } else {
            avail_mem = task.memory.toGiga()
        }
        prefix = params.protocol == 'amplicon' ? "${sample}.trim.mkD" : "${sample}.mkD"
        keep_dup = params.filter_dups ? "true" : "false"
        """
        picard -Xmx${avail_mem}g MarkDuplicates \\
            INPUT=${bam[0]} \\
            OUTPUT=${prefix}.sorted.bam \\
            ASSUME_SORTED=true \\
            REMOVE_DUPLICATES=$keep_dup \\
            METRICS_FILE=${prefix}.MarkDuplicates.metrics.txt \\
            VALIDATION_STRINGENCY=LENIENT \\
            TMP_DIR=tmp
        samtools index ${prefix}.sorted.bam
        samtools idxstats ${prefix}.sorted.bam > ${prefix}.sorted.bam.idxstats
        samtools flagstat ${prefix}.sorted.bam > ${prefix}.sorted.bam.flagstat
        samtools stats ${prefix}.sorted.bam > ${prefix}.sorted.bam.stats
        """
    }
}

/*
 * STEP 5.5: Picard CollectMultipleMetrics and CollectWgsMetrics
 */
process PICARD_METRICS {
    tag "$sample"
    label 'process_medium'
    publishDir "${params.outdir}/variants/bam/picard_metrics", mode: params.publish_dir_mode

    when:
    !params.skip_variants && !params.skip_picard_metrics

    input:
    tuple val(sample), val(single_end), path(bam) from ch_markdup_bam_metrics
    path fasta from ch_fasta

    output:
    path "*metrics" into ch_picard_metrics_mqc
    path "*.pdf"

    script:
    def avail_mem = 3
    if (!task.memory) {
        log.info "[Picard CollectMultipleMetrics] Available memory not known - defaulting to 3GB. Specify process memory requirements to change this."
    } else {
        avail_mem = task.memory.toGiga()
    }
    suffix = params.skip_markduplicates ? "" : ".mkD"
    prefix = params.protocol == 'amplicon' ? "${sample}.trim${suffix}" : "${sample}${suffix}"
    """
    picard -Xmx${avail_mem}g CollectMultipleMetrics \\
        INPUT=${bam[0]} \\
        OUTPUT=${prefix}.CollectMultipleMetrics \\
        REFERENCE_SEQUENCE=$fasta \\
        VALIDATION_STRINGENCY=LENIENT \\
        TMP_DIR=tmp

    picard -Xmx${avail_mem}g CollectWgsMetrics \\
        COVERAGE_CAP=1000000 \\
        INPUT=${bam[0]} \\
        OUTPUT=${prefix}.CollectWgsMetrics.coverage_metrics \\
        REFERENCE_SEQUENCE=$fasta \\
        VALIDATION_STRINGENCY=LENIENT \\
        TMP_DIR=tmp
    """
}

/*
 * STEP 5.6.1: mosdepth genome-wide coverage
 */
process MOSDEPTH_GENOME {
    tag "$sample"
    label 'process_medium'
    publishDir "${params.outdir}/variants/bam/mosdepth/genome", mode: params.publish_dir_mode,
        saveAs: { filename ->
                      if (filename.endsWith(".pdf")) "plots/$filename"
                      else if (filename.endsWith(".tsv")) "plots/$filename"
                      else filename
                }

    when:
    !params.skip_variants && !params.skip_mosdepth

    input:
    tuple val(sample), val(single_end), path(bam) from ch_markdup_bam_mosdepth_genome

    output:
    path "*.global.dist.txt" into ch_mosdepth_genome_mqc
    path "*.{txt,gz,csi,tsv,pdf}"

    script:
    suffix = params.skip_markduplicates ? "" : ".mkD"
    prefix = params.protocol == 'amplicon' ? "${sample}.trim${suffix}.genome" : "${sample}${suffix}.genome"
    plot_suffix = params.protocol == 'amplicon' ? ".trim${suffix}.genome" : "${suffix}.genome"
    """
    mosdepth \\
        --by 200 \\
        --fast-mode \\
        $prefix \\
        ${bam[0]}

    plot_mosdepth_regions.r \\
        --input_files ${prefix}.regions.bed.gz \\
        --input_suffix ${plot_suffix}.regions.bed.gz \\
        --output_dir ./ \\
        --output_suffix ${plot_suffix}.regions
    """
}

/*
 * STEP 5.6.2: mosdepth amplicon coverage and plots
 */
if (params.protocol == 'amplicon') {
    process MOSDEPTH_AMPLICON {
        tag "$sample"
        label 'process_medium'
        publishDir "${params.outdir}/variants/bam/mosdepth/amplicon", mode: params.publish_dir_mode

        when:
        !params.skip_variants && !params.skip_mosdepth

        input:
        tuple val(sample), val(single_end), path(bam) from ch_markdup_bam_mosdepth_amplicon
        path bed from ch_amplicon_bed

        output:
        path "*.regions.bed.gz" into ch_mosdepth_amplicon_region_bed
        path "*.{txt,gz,csi}"

        script:
        suffix = params.skip_markduplicates ? "" : ".mkD"
        prefix = "${sample}.trim${suffix}.amplicon"
        """
        collapse_amplicon_bed.py \\
            --left_primer_suffix $params.amplicon_left_suffix \\
            --right_primer_suffix $params.amplicon_right_suffix \\
            $bed \\
            amplicon.collapsed.bed

        mosdepth \\
            --by amplicon.collapsed.bed \\
            --fast-mode \\
            --use-median \\
            --thresholds 0,1,10,50,100,500 \\
            ${prefix} \\
            ${bam[0]}
        """
    }

    process MOSDEPTH_AMPLICON_PLOT {
        label 'process_medium'
        publishDir "${params.outdir}/variants/bam/mosdepth/amplicon/plots", mode: params.publish_dir_mode

        when:
        !params.skip_variants && !params.skip_mosdepth

        input:
        path bed from ch_mosdepth_amplicon_region_bed.collect()

        output:
        path "*.{tsv,pdf}"

        script:
        suffix = params.skip_markduplicates ? "" : ".mkD"
        suffix = ".trim${suffix}.amplicon"
        """
        plot_mosdepth_regions.r \\
            --input_files ${bed.join(',')} \\
            --input_suffix ${suffix}.regions.bed.gz \\
            --output_dir ./ \\
            --output_suffix ${suffix}.regions
        """
    }
}

////////////////////////////////////////////////////
/* --              VARSCAN2                    -- */
////////////////////////////////////////////////////

/*
 * STEP 5.7: Create mpileup file for all variant callers
 */
process SAMTOOLS_MPILEUP {
    tag "$sample"
    label 'process_medium'
    if (params.save_mpileup) {
        publishDir "${params.outdir}/variants/bam/mpileup", mode: params.publish_dir_mode
    }

    when:
    !params.skip_variants

    input:
    tuple val(sample), val(single_end), path(bam) from ch_markdup_bam_mpileup
    path fasta from ch_fasta

    output:
    tuple val(sample), val(single_end), path("*.mpileup") into ch_mpileup_varscan2,
                                                               ch_mpileup_ivar_variants,
                                                               ch_mpileup_ivar_consensus,
                                                               ch_mpileup_ivar_bcftools

    script:
    suffix = params.skip_markduplicates ? "" : ".mkD"
    prefix = params.protocol == 'amplicon' ? "${sample}.trim${suffix}" : "${sample}${suffix}"
    """
    samtools mpileup \\
        --count-orphans \\
        --no-BAQ \\
        --max-depth $params.mpileup_depth \\
        --fasta-ref $fasta \\
        --min-BQ $params.min_base_qual \\
        --output ${prefix}.mpileup \\
        ${bam[0]}
    """
}

/*
 * STEP 5.7.1: Variant calling with VarScan 2
 */
process VARSCAN2 {
    tag "$sample"
    label 'process_medium'
    publishDir "${params.outdir}/variants/varscan2", mode: params.publish_dir_mode,
        saveAs: { filename ->
                      if (filename.endsWith(".log")) "log/$filename"
                      else if (filename.endsWith(".txt")) "bcftools_stats/$filename"
                      else filename
                }

    when:
    !params.skip_variants && 'varscan2' in callers

    input:
    tuple val(sample), val(single_end), path(mpileup) from ch_mpileup_varscan2
    path fasta from ch_fasta

    output:
    tuple val(sample), val(single_end), path("${prefix}.vcf.gz*") into ch_varscan2_highfreq_consensus,
                                                                       ch_varscan2_highfreq_snpeff,
                                                                       ch_varscan2_highfreq_intersect
    tuple val(sample), val(single_end), path("${sample}.vcf.gz*") into ch_varscan2_lowfreq_snpeff
    path "${prefix}.bcftools_stats.txt" into ch_varscan2_bcftools_highfreq_mqc
    path "*.varscan2.log" into ch_varscan2_log_mqc
    path "${sample}.bcftools_stats.txt"

    script:
    prefix = "${sample}.AF${params.max_allele_freq}"
    strand = params.protocol != 'amplicon' && params.varscan2_strand_filter ? "--strand-filter 1" : "--strand-filter 0"
    """
    echo "$sample" > sample_name.list
    varscan mpileup2cns \\
        $mpileup \\
        --min-coverage $params.min_coverage \\
        --min-reads2 5 \\
        --min-avg-qual $params.min_base_qual \\
        --min-var-freq $params.min_allele_freq \\
        --p-value 0.99 \\
        --output-vcf 1 \\
        --vcf-sample-list sample_name.list \\
        --variants \\
        $strand \\
        2> ${sample}.varscan2.log \\
        | bgzip -c > ${sample}.vcf.gz
    tabix -p vcf -f ${sample}.vcf.gz
    bcftools stats ${sample}.vcf.gz > ${sample}.bcftools_stats.txt
    sed -i.bak '/LC_ALL/d' ${sample}.varscan2.log

    bcftools filter \\
        -i 'FORMAT/AD / (FORMAT/AD + FORMAT/RD) >= $params.max_allele_freq' \\
        --output-type z \\
        --output ${prefix}.vcf.gz \\
        ${sample}.vcf.gz
    tabix -p vcf -f ${prefix}.vcf.gz
    bcftools stats ${prefix}.vcf.gz > ${prefix}.bcftools_stats.txt
    """
}

/*
 * STEP 5.7.1.1: Genome consensus generation with BCFtools and masked with BEDTools
 */
process VARSCAN2_CONSENSUS {
    tag "$sample"
    label 'process_medium'
    publishDir "${params.outdir}/variants/varscan2/consensus", mode: params.publish_dir_mode,
        saveAs: { filename ->
                      if (filename.endsWith(".tsv")) "base_qc/$filename"
                      else if (filename.endsWith(".pdf")) "base_qc/$filename"
                      else filename
                }

    when:
    !params.skip_variants && 'varscan2' in callers

    input:
    tuple val(sample), val(single_end), path(bam), path(vcf) from ch_markdup_bam_varscan2_consensus.join(ch_varscan2_highfreq_consensus, by: [0,1])
    path fasta from ch_fasta

    output:
    tuple val(sample), val(single_end), path("*consensus.masked.fa") into ch_varscan2_consensus
    path "*.{consensus.fa,tsv,pdf}"

    script:
    prefix = "${sample}.AF${params.max_allele_freq}"
    """
    cat $fasta | bcftools consensus ${vcf[0]} > ${prefix}.consensus.fa

    bedtools genomecov \\
        -bga \\
        -ibam ${bam[0]} \\
        -g $fasta \\
        | awk '\$4 < $params.min_coverage' | bedtools merge > ${prefix}.mask.bed

    bedtools maskfasta \\
        -fi ${prefix}.consensus.fa \\
        -bed ${prefix}.mask.bed \\
        -fo ${prefix}.consensus.masked.fa
    header=\$(head -n 1 ${prefix}.consensus.masked.fa | sed 's/>//g')
    sed -i "s/\${header}/${sample}/g" ${prefix}.consensus.masked.fa

    plot_base_density.r --fasta_files ${prefix}.consensus.masked.fa --prefixes $prefix --output_dir ./
    """
}

/*
 * STEP 5.7.1.2: VarScan 2 variant calling annotation with SnpEff and SnpSift
 */
process VARSCAN2_SNPEFF {
    tag "$sample"
    label 'process_medium'
    publishDir "${params.outdir}/variants/varscan2/snpeff", mode: params.publish_dir_mode

    when:
    !params.skip_variants && 'varscan2' in callers && params.gff && !params.skip_snpeff

    input:
    tuple val(sample), val(single_end), path(highfreq_vcf), path(lowfreq_vcf) from ch_varscan2_highfreq_snpeff.join(ch_varscan2_lowfreq_snpeff, by: [0,1])
    tuple file(db), file(config) from ch_snpeff_db_varscan2

    output:
    path "${prefix}.snpEff.csv" into ch_varscan2_snpeff_highfreq_mqc
    path "${sample}.snpEff.csv"
    path "*.vcf.gz*"
    path "*.{txt,html}"

    script:
    prefix = "${sample}.AF${params.max_allele_freq}"
    """
    snpEff ${index_base} \\
        -config $config \\
        -dataDir $db \\
        ${lowfreq_vcf[0]} \\
        -csvStats ${sample}.snpEff.csv \\
        | bgzip -c > ${sample}.snpEff.vcf.gz
    tabix -p vcf -f ${sample}.snpEff.vcf.gz
    mv snpEff_summary.html ${sample}.snpEff.summary.html

    SnpSift extractFields -s "," \\
        -e "." \\
        ${sample}.snpEff.vcf.gz \\
        CHROM POS REF ALT \\
        "ANN[*].GENE" "ANN[*].GENEID" \\
        "ANN[*].IMPACT" "ANN[*].EFFECT" \\
        "ANN[*].FEATURE" "ANN[*].FEATUREID" \\
        "ANN[*].BIOTYPE" "ANN[*].RANK" "ANN[*].HGVS_C" \\
        "ANN[*].HGVS_P" "ANN[*].CDNA_POS" "ANN[*].CDNA_LEN" \\
        "ANN[*].CDS_POS" "ANN[*].CDS_LEN" "ANN[*].AA_POS" \\
        "ANN[*].AA_LEN" "ANN[*].DISTANCE" "EFF[*].EFFECT" \\
        "EFF[*].FUNCLASS" "EFF[*].CODON" "EFF[*].AA" "EFF[*].AA_LEN" \\
        > ${sample}.snpSift.table.txt

    snpEff ${index_base} \\
        -config $config \\
        -dataDir $db \\
        ${highfreq_vcf[0]} \\
        -csvStats ${prefix}.snpEff.csv \\
        | bgzip -c > ${prefix}.snpEff.vcf.gz
    tabix -p vcf -f ${prefix}.snpEff.vcf.gz
    mv snpEff_summary.html ${prefix}.snpEff.summary.html

    SnpSift extractFields -s "," \\
        -e "." \\
        ${prefix}.snpEff.vcf.gz \\
        CHROM POS REF ALT \\
        "ANN[*].GENE" "ANN[*].GENEID" \\
        "ANN[*].IMPACT" "ANN[*].EFFECT" \\
        "ANN[*].FEATURE" "ANN[*].FEATUREID" \\
        "ANN[*].BIOTYPE" "ANN[*].RANK" "ANN[*].HGVS_C" \\
        "ANN[*].HGVS_P" "ANN[*].CDNA_POS" "ANN[*].CDNA_LEN" \\
        "ANN[*].CDS_POS" "ANN[*].CDS_LEN" "ANN[*].AA_POS" \\
        "ANN[*].AA_LEN" "ANN[*].DISTANCE" "EFF[*].EFFECT" \\
        "EFF[*].FUNCLASS" "EFF[*].CODON" "EFF[*].AA" "EFF[*].AA_LEN" \\
        > ${prefix}.snpSift.table.txt
    	"""
}

/*
 * STEP 5.7.1.3: VarScan 2 consensus sequence report with QUAST
 */
process VARSCAN2_QUAST {
    label 'process_medium'
    publishDir "${params.outdir}/variants/varscan2/quast", mode: params.publish_dir_mode,
        saveAs: { filename ->
                      if (!filename.endsWith(".tsv")) filename
                }

    when:
    !params.skip_variants && 'varscan2' in callers && !params.skip_variants_quast

    input:
    path consensus from ch_varscan2_consensus.collect{ it[2] }
    path fasta from ch_fasta
    path gff from ch_gff

    output:
    path "AF${params.max_allele_freq}"
    path "report.tsv" into ch_varscan2_quast_mqc

    script:
    features = params.gff ? "--features $gff" : ""
    """
    quast.py \\
        --output-dir AF${params.max_allele_freq} \\
        -r $fasta \\
        $features \\
        --threads $task.cpus \\
        ${consensus.join(' ')}
    ln -s AF${params.max_allele_freq}/report.tsv
    """
}

////////////////////////////////////////////////////
/* --                IVAR                      -- */
////////////////////////////////////////////////////

/*
 * STEP 5.7.2: Variant calling with iVar
 */
process IVAR_VARIANTS {
    tag "$sample"
    label 'process_medium'
    publishDir "${params.outdir}/variants/ivar", mode: params.publish_dir_mode,
        saveAs: { filename ->
                      if (filename.endsWith(".bcftools_stats.txt")) "bcftools_stats/$filename"
                      else if (filename.endsWith(".log")) "log/$filename"
                      else if (filename.endsWith("_mqc.tsv")) null
                      else filename
                }

    when:
    !params.skip_variants && 'ivar' in callers

    input:
    tuple val(sample), val(single_end), path(mpileup) from ch_mpileup_ivar_variants
    path header from ch_ivar_variants_header_mqc
    path fasta from ch_fasta
    path gff from ch_gff

    output:
    tuple val(sample), val(single_end), path("${prefix}.vcf.gz*") into ch_ivar_highfreq_snpeff,
                                                                       ch_ivar_highfreq_intersect
    tuple val(sample), val(single_end), path("${sample}.vcf.gz*") into ch_ivar_lowfreq_snpeff
    path "${prefix}.bcftools_stats.txt" into ch_ivar_bcftools_highfreq_mqc
    path "${sample}.variant.counts_mqc.tsv" into ch_ivar_count_mqc
    path "${sample}.bcftools_stats.txt"
    path "${sample}.tsv"
    path "*.log"

    script:
    features = params.gff ? "-g $gff" : ""
    prefix = "${sample}.AF${params.max_allele_freq}"
    """
    cat $mpileup | ivar variants -q $params.min_base_qual -t $params.min_allele_freq -m $params.min_coverage -r $fasta $features -p $sample

    ivar_variants_to_vcf.py ${sample}.tsv ${sample}.vcf > ${sample}.variant.counts.log
    bgzip -c ${sample}.vcf > ${sample}.vcf.gz
    tabix -p vcf -f ${sample}.vcf.gz
    bcftools stats ${sample}.vcf.gz > ${sample}.bcftools_stats.txt
    cat $header ${sample}.variant.counts.log > ${sample}.variant.counts_mqc.tsv

    ivar_variants_to_vcf.py ${sample}.tsv ${prefix}.vcf --pass_only --allele_freq_thresh $params.max_allele_freq > ${prefix}.variant.counts.log
    bgzip -c ${prefix}.vcf > ${prefix}.vcf.gz
    tabix -p vcf -f ${prefix}.vcf.gz
    bcftools stats ${prefix}.vcf.gz > ${prefix}.bcftools_stats.txt
    """
}

/*
 * STEP 5.7.2.1: Generate consensus sequence with iVar
 */
process IVAR_CONSENSUS {
    tag "$sample"
    label 'process_medium'
    publishDir "${params.outdir}/variants/ivar/consensus", mode: params.publish_dir_mode,
        saveAs: { filename ->
                      if (filename.endsWith(".tsv")) "base_qc/$filename"
                      else if (filename.endsWith(".pdf")) "base_qc/$filename"
                      else filename
                }

    when:
    !params.skip_variants && 'ivar' in callers

    input:
    tuple val(sample), val(single_end), path(mpileup) from ch_mpileup_ivar_consensus
    path fasta from ch_fasta

    output:
    tuple val(sample), val(single_end), path("*.fa") into ch_ivar_consensus
    path "*.{txt,tsv,pdf}"

    script:
    prefix = "${sample}.AF${params.max_allele_freq}"
    """
    cat $mpileup | ivar consensus -q $params.min_base_qual -t $params.max_allele_freq -m $params.min_coverage -n N -p ${prefix}.consensus
    header=\$(head -n1 ${prefix}.consensus.fa | sed 's/>//g')
    sed -i "s/\${header}/${sample}/g" ${prefix}.consensus.fa

    plot_base_density.r --fasta_files ${prefix}.consensus.fa --prefixes $prefix --output_dir ./
    """
}

/*
 * STEP 5.7.2.2: iVar variant calling annotation with SnpEff and SnpSift
 */
process IVAR_SNPEFF {
    tag "$sample"
    label 'process_medium'
    publishDir "${params.outdir}/variants/ivar/snpeff", mode: params.publish_dir_mode

    when:
    !params.skip_variants && 'ivar' in callers && params.gff && !params.skip_snpeff

    input:
    tuple val(sample), val(single_end), path(highfreq_vcf), path(lowfreq_vcf) from ch_ivar_highfreq_snpeff.join(ch_ivar_lowfreq_snpeff, by: [0,1])
    tuple file(db), file(config) from ch_snpeff_db_ivar

    output:
    path "${prefix}.snpEff.csv" into ch_ivar_snpeff_highfreq_mqc
    path "${sample}.snpEff.csv"
    path "*.vcf.gz*"
    path "*.{txt,html}"

    script:
    prefix = "${sample}.AF${params.max_allele_freq}"
    """
    snpEff ${index_base} \\
        -config $config \\
        -dataDir $db \\
        ${lowfreq_vcf[0]} \\
        -csvStats ${sample}.snpEff.csv \\
        | bgzip -c > ${sample}.snpEff.vcf.gz
    tabix -p vcf -f ${sample}.snpEff.vcf.gz
    mv snpEff_summary.html ${sample}.snpEff.summary.html

    SnpSift extractFields -s "," \\
        -e "." \\
        ${sample}.snpEff.vcf.gz \\
        CHROM POS REF ALT \\
        "ANN[*].GENE" "ANN[*].GENEID" \\
        "ANN[*].IMPACT" "ANN[*].EFFECT" \\
        "ANN[*].FEATURE" "ANN[*].FEATUREID" \\
        "ANN[*].BIOTYPE" "ANN[*].RANK" "ANN[*].HGVS_C" \\
        "ANN[*].HGVS_P" "ANN[*].CDNA_POS" "ANN[*].CDNA_LEN" \\
        "ANN[*].CDS_POS" "ANN[*].CDS_LEN" "ANN[*].AA_POS" \\
        "ANN[*].AA_LEN" "ANN[*].DISTANCE" "EFF[*].EFFECT" \\
        "EFF[*].FUNCLASS" "EFF[*].CODON" "EFF[*].AA" "EFF[*].AA_LEN" \\
        > ${sample}.snpSift.table.txt

    snpEff ${index_base} \\
        -config $config \\
        -dataDir $db \\
        ${highfreq_vcf[0]} \\
        -csvStats ${prefix}.snpEff.csv \\
        | bgzip -c > ${prefix}.snpEff.vcf.gz
    tabix -p vcf -f ${prefix}.snpEff.vcf.gz
    mv snpEff_summary.html ${prefix}.snpEff.summary.html

    SnpSift extractFields -s "," \\
        -e "." \\
        ${prefix}.snpEff.vcf.gz \\
        CHROM POS REF ALT \\
        "ANN[*].GENE" "ANN[*].GENEID" \\
        "ANN[*].IMPACT" "ANN[*].EFFECT" \\
        "ANN[*].FEATURE" "ANN[*].FEATUREID" \\
        "ANN[*].BIOTYPE" "ANN[*].RANK" "ANN[*].HGVS_C" \\
        "ANN[*].HGVS_P" "ANN[*].CDNA_POS" "ANN[*].CDNA_LEN" \\
        "ANN[*].CDS_POS" "ANN[*].CDS_LEN" "ANN[*].AA_POS" \\
        "ANN[*].AA_LEN" "ANN[*].DISTANCE" "EFF[*].EFFECT" \\
        "EFF[*].FUNCLASS" "EFF[*].CODON" "EFF[*].AA" "EFF[*].AA_LEN" \\
        > ${prefix}.snpSift.table.txt
   	"""
}

/*
 * STEP 5.7.2.3: iVar consensus sequence report with QUAST
 */
process IVAR_QUAST {
    label 'process_medium'
    publishDir "${params.outdir}/variants/ivar/quast", mode: params.publish_dir_mode,
        saveAs: { filename ->
                      if (!filename.endsWith(".tsv")) filename
                }

    when:
    !params.skip_variants && 'ivar' in callers && !params.skip_variants_quast

    input:
    path consensus from ch_ivar_consensus.collect{ it[2] }
    path fasta from ch_fasta
    path gff from ch_gff

    output:
    path "AF${params.max_allele_freq}"
    path "report.tsv" into ch_ivar_quast_mqc

    script:
    features = params.gff ? "--features $gff" : ""
    """
    quast.py \\
        --output-dir AF${params.max_allele_freq} \\
        -r $fasta \\
        $features \\
        --threads $task.cpus \\
        ${consensus.join(' ')}
    ln -s AF${params.max_allele_freq}/report.tsv
    """
}

////////////////////////////////////////////////////
/* --              BCFTOOLS                    -- */
////////////////////////////////////////////////////

/*
 * STEP 5.7.3: Variant calling with BCFTools
 */
process BCFTOOLS_VARIANTS {
    tag "$sample"
    label 'process_medium'
    publishDir "${params.outdir}/variants/bcftools", mode: params.publish_dir_mode,
        saveAs: { filename ->
                      if (filename.endsWith(".txt")) "bcftools_stats/$filename"
                      else filename
                }

    when:
    !params.skip_variants && 'bcftools' in callers

    input:
    tuple val(sample), val(single_end), path(bam) from ch_markdup_bam_bcftools
    path fasta from ch_fasta

    output:
    tuple val(sample), val(single_end), path("*.vcf.gz*") into ch_bcftools_variants_consensus,
                                                               ch_bcftools_variants_snpeff,
                                                               ch_bcftools_variants_intersect
    path "*.bcftools_stats.txt" into ch_bcftools_variants_mqc

    script:
    """
    echo "$sample" > sample_name.list
    bcftools mpileup \\
        --count-orphans \\
        --no-BAQ \\
        --max-depth $params.mpileup_depth \\
        --fasta-ref $fasta \\
        --min-BQ $params.min_base_qual \\
        --annotate FORMAT/AD,FORMAT/ADF,FORMAT/ADR,FORMAT/DP,FORMAT/SP,INFO/AD,INFO/ADF,INFO/ADR \\
        ${bam[0]} \\
        | bcftools call --output-type v --ploidy 1 --keep-alts --keep-masked-ref --multiallelic-caller --variants-only \\
        | bcftools reheader --samples sample_name.list \\
        | bcftools view --output-file ${sample}.vcf.gz --output-type z --include 'INFO/DP>=$params.min_coverage'
    tabix -p vcf -f ${sample}.vcf.gz
    bcftools stats ${sample}.vcf.gz > ${sample}.bcftools_stats.txt
    """
}

/*
 * STEP 5.7.3.1: Genome consensus generation with BCFtools and masked with BEDTools
 */
process BCFTOOLS_CONSENSUS {
    tag "$sample"
    label 'process_medium'
    publishDir "${params.outdir}/variants/bcftools/consensus", mode: params.publish_dir_mode,
        saveAs: { filename ->
                      if (filename.endsWith(".tsv")) "base_qc/$filename"
                      else if (filename.endsWith(".pdf")) "base_qc/$filename"
                      else filename
                }

    when:
    !params.skip_variants && 'bcftools' in callers

    input:
    tuple val(sample), val(single_end), path(bam), path(vcf) from ch_markdup_bam_bcftools_consensus.join(ch_bcftools_variants_consensus, by: [0,1])
    path fasta from ch_fasta

    output:
    tuple val(sample), val(single_end), path("*consensus.masked.fa") into ch_bcftools_consensus_masked
    path "*.{consensus.fa,tsv,pdf}"

    script:
    """
    cat $fasta | bcftools consensus ${vcf[0]} > ${sample}.consensus.fa

    bedtools genomecov \\
        -bga \\
        -ibam ${bam[0]} \\
        -g $fasta \\
        | awk '\$4 < $params.min_coverage' | bedtools merge > ${sample}.mask.bed

    bedtools maskfasta \\
        -fi ${sample}.consensus.fa \\
        -bed ${sample}.mask.bed \\
        -fo ${sample}.consensus.masked.fa
    sed -i 's/${index_base}/${sample}/g' ${sample}.consensus.masked.fa
    header=\$(head -n1 ${sample}.consensus.masked.fa | sed 's/>//g')
    sed -i "s/\${header}/${sample}/g" ${sample}.consensus.masked.fa

    plot_base_density.r --fasta_files ${sample}.consensus.masked.fa --prefixes $sample --output_dir ./
    """
}

/*
 * STEP 5.7.3.2: BCFTools variant calling annotation with SnpEff and SnpSift
 */
process BCFTOOLS_SNPEFF {
    tag "$sample"
    label 'process_medium'
    publishDir "${params.outdir}/variants/bcftools/snpeff", mode: params.publish_dir_mode

    when:
    !params.skip_variants && 'bcftools' in callers && params.gff && !params.skip_snpeff

    input:
    tuple val(sample), val(single_end), path(vcf) from ch_bcftools_variants_snpeff
    tuple file(db), file(config) from ch_snpeff_db_bcftools

    output:
    path "*.snpEff.csv" into ch_bcftools_snpeff_mqc
    path "*.vcf.gz*"
    path "*.{txt,html}"

    script:
    """
    snpEff ${index_base} \\
        -config $config \\
        -dataDir $db \\
        ${vcf[0]} \\
        -csvStats ${sample}.snpEff.csv \\
        | bgzip -c > ${sample}.snpEff.vcf.gz
    tabix -p vcf -f ${sample}.snpEff.vcf.gz
    mv snpEff_summary.html ${sample}.snpEff.summary.html

    SnpSift extractFields -s "," \\
        -e "." \\
        ${sample}.snpEff.vcf.gz \\
        CHROM POS REF ALT \\
        "ANN[*].GENE" "ANN[*].GENEID" \\
        "ANN[*].IMPACT" "ANN[*].EFFECT" \\
        "ANN[*].FEATURE" "ANN[*].FEATUREID" \\
        "ANN[*].BIOTYPE" "ANN[*].RANK" "ANN[*].HGVS_C" \\
        "ANN[*].HGVS_P" "ANN[*].CDNA_POS" "ANN[*].CDNA_LEN" \\
        "ANN[*].CDS_POS" "ANN[*].CDS_LEN" "ANN[*].AA_POS" \\
        "ANN[*].AA_LEN" "ANN[*].DISTANCE" "EFF[*].EFFECT" \\
        "EFF[*].FUNCLASS" "EFF[*].CODON" "EFF[*].AA" "EFF[*].AA_LEN" \\
        > ${sample}.snpSift.table.txt
    	"""
}

/*
 * STEP 5.7.3.3: BCFTools consensus sequence report with QUAST
 */
process BCFTOOLS_QUAST {
    label 'process_medium'
    publishDir "${params.outdir}/variants/bcftools", mode: params.publish_dir_mode,
        saveAs: { filename ->
                      if (!filename.endsWith(".tsv")) filename
                }

    when:
    !params.skip_variants && 'bcftools' in callers && !params.skip_variants_quast

    input:
    path consensus from ch_bcftools_consensus_masked.collect{ it[2] }
    path fasta from ch_fasta
    path gff from ch_gff

    output:
    path "quast"
    path "report.tsv" into ch_bcftools_quast_mqc

    script:
    features = params.gff ? "--features $gff" : ""
    """
    quast.py \\
        --output-dir quast \\
        -r $fasta \\
        $features \\
        --threads $task.cpus \\
        ${consensus.join(' ')}
    ln -s quast/report.tsv
    """
}

////////////////////////////////////////////////////
/* --            INTERSECT VARIANTS            -- */
////////////////////////////////////////////////////

/*
 * STEP 5.8: Intersect variants with BCFTools
 */
if (!params.skip_variants && callers.size() > 2) {

    ch_varscan2_highfreq_intersect
        .join(ch_ivar_highfreq_intersect, by: [0,1])
        .join(ch_bcftools_variants_intersect, by: [0,1])
        .set { ch_varscan2_highfreq_intersect }

    process BCFTOOLS_ISEC {
        tag "$sample"
        label 'process_medium'
        label 'error_ignore'
        publishDir "${params.outdir}/variants/intersect", mode: params.publish_dir_mode

        input:
        tuple val(sample), val(single_end), path('varscan2/*'), path('ivar/*'), path('bcftools/*') from ch_varscan2_highfreq_intersect

        output:
        path "$sample"

        script:
        """
        bcftools isec  \\
            --nfiles +2 \\
            --output-type z \\
            -p $sample \\
            */*.vcf.gz
        """
    }
}

///////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////
/* --                                                                     -- */
/* --                          MULTIQC                                    -- */
/* --                                                                     -- */
///////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////

Channel.from(summary.collect{ [it.key, it.value] })
    .map { k,v -> "<dt>$k</dt><dd><samp>${v ?: '<span style=\"color:#999999;\">N/A</a>'}</samp></dd>" }
    .reduce { a, b -> return [a, b].join("\n            ") }
    .map { x -> """
    id: 'nf-core-viralrecon-summary'
    description: " - this information is collected when the pipeline is started."
    section_name: 'nf-core/viralrecon Workflow Summary'
    section_href: 'https://github.com/nf-core/viralrecon'
    plot_type: 'html'
    data: |
        <dl class=\"dl-horizontal\">
            $x
        </dl>
    """.stripIndent() }
    .set { ch_workflow_summary }

/*
 * Parse software version numbers
 */
process get_software_versions {
    publishDir "${params.outdir}/pipeline_info", mode: params.publish_dir_mode,
        saveAs: { filename ->
                      if (filename.endsWith(".csv")) filename
                      else null
                }

    output:
    path "software_versions_mqc.yaml" into ch_software_versions_yaml
    path "software_versions.csv"

    script:
    """
    echo $workflow.manifest.version > v_pipeline.txt
    echo $workflow.nextflow.version > v_nextflow.txt
    parallel-fastq-dump --version > v_parallel_fastq_dump.txt
    fastqc --version > v_fastqc.txt
    fastp --version 2> v_fastp.txt
    bowtie2 --version > v_bowtie2.txt
    samtools --version > v_samtools.txt
    bedtools --version > v_bedtools.txt
    mosdepth --version > v_mosdepth.txt
    picard CollectMultipleMetrics --version &> v_picard.txt || true
    ivar -v > v_ivar.txt
    echo \$(varscan 2>&1) > v_varscan.txt
    bcftools -v > v_bcftools.txt
    snpEff -version > v_snpeff.txt
    echo \$(SnpSift 2>&1) > v_snpsift.txt
    quast.py --version > v_quast.txt
    cutadapt --version > v_cutadapt.txt
    kraken2 --version > v_kraken2.txt
    spades.py --version > v_spades.txt
    unicycler --version > v_unicycler.txt
    minia --version > v_minia.txt
    blastn -version > v_blast.txt
    abacas.pl -v &> v_abacas.txt || true
    plasmidID -v > v_plasmidid.txt  || true
    Bandage --version > v_bandage.txt
    minimap2 --version > v_minimap2.txt
    vg version > v_vg.txt
    echo \$(R --version 2>&1) > v_R.txt
    multiqc --version > v_multiqc.txt
    scrape_software_versions.py &> software_versions_mqc.yaml
    """
}

/*
 * STEP 7: MultiQC
 */
process MULTIQC {
    label 'process_medium'
    publishDir "${params.outdir}", mode: params.publish_dir_mode,
        saveAs: { filename ->
                      if (filename.endsWith("assembly_metrics_mqc.tsv")) "assembly/$filename"
                      else if (filename.endsWith("variants_metrics_mqc.tsv")) "variants/$filename"
                      else "multiqc/$filename"
                }

    when:
    !params.skip_multiqc

    input:
    path (multiqc_config) from ch_multiqc_config
    path (mqc_custom_config) from ch_multiqc_custom_config.collect().ifEmpty([])
    path ('fastqc/*') from ch_fastqc_raw_reports_mqc.collect().ifEmpty([])
    path ('fastp/log/*') from ch_fastp_mqc.collect().ifEmpty([])
    path ('fastp/fastqc/*') from ch_fastp_fastqc_mqc.collect().ifEmpty([])
    path ('bowtie2/log/*') from ch_bowtie2_mqc.collect().ifEmpty([])
    path ('bowtie2/flagstat/*') from ch_sort_bam_flagstat_mqc.collect().ifEmpty([])
    path ('ivar/trim/flagstat/*') from ch_ivar_trim_flagstat_mqc.collect().ifEmpty([])
    path ('ivar/trim/log/*') from ch_ivar_trim_log_mqc.collect().ifEmpty([])
    path ('picard/markdup/*') from ch_markdup_bam_flagstat_mqc.collect().ifEmpty([])
    path ('picard/metrics/*') from ch_markdup_bam_metrics_mqc.collect().ifEmpty([])
    path ('picard/metrics/*') from ch_picard_metrics_mqc.collect().ifEmpty([])
    path ('mosdepth/genome/*') from ch_mosdepth_genome_mqc.collect().ifEmpty([])
    path ('varscan2/counts/lowfreq/*') from ch_varscan2_log_mqc.collect().ifEmpty([])
    path ('varscan2/bcftools/highfreq/*') from ch_varscan2_bcftools_highfreq_mqc.collect().ifEmpty([])
    path ('varscan2/snpeff/highfreq/*') from ch_varscan2_snpeff_highfreq_mqc.collect().ifEmpty([])
    path ('varscan2/quast/highfreq/*') from ch_varscan2_quast_mqc.collect().ifEmpty([])
    path ('ivar/variants/counts/lowfreq/*') from ch_ivar_count_mqc.collect().ifEmpty([])
    path ('ivar/variants/bcftools/highfreq/*') from ch_ivar_bcftools_highfreq_mqc.collect().ifEmpty([])
    path ('ivar/variants/snpeff/highfreq/*') from ch_ivar_snpeff_highfreq_mqc.collect().ifEmpty([])
    path ('ivar/consensus/quast/highfreq/*') from ch_ivar_quast_mqc.collect().ifEmpty([])
    path ('bcftools/variants/bcftools/*') from ch_bcftools_variants_mqc.collect().ifEmpty([])
    path ('bcftools/variants/snpeff/*') from ch_bcftools_snpeff_mqc.collect().ifEmpty([])
    path ('bcftools/consensus/quast/*') from ch_bcftools_quast_mqc.collect().ifEmpty([])
    path ('kraken2/*') from ch_kraken2_report_mqc.collect().ifEmpty([])

    path ('software_versions/*') from ch_software_versions_yaml.collect()
    path workflow_summary from ch_workflow_summary.collectFile(name: "workflow_summary_mqc.yaml")

    output:
    path "*multiqc_report.html" into ch_multiqc_report
    path "*_data"
    path "*.tsv"

    script:
    rtitle = custom_runName ? "--title \"$custom_runName\"" : ''
    rfilename = custom_runName ? "--filename " + custom_runName.replaceAll('\\W','_').replaceAll('_+','_') + "_multiqc_report" : ''
    custom_config_file = params.multiqc_config ? "--config $mqc_custom_config" : ''
    """
    multiqc . -f $rtitle $rfilename $custom_config_file
    multiqc_to_custom_tsv.py
    multiqc . -f $rtitle $rfilename $custom_config_file
    """
}

process output_documentation {
    publishDir "${params.outdir}/pipeline_info", mode: params.publish_dir_mode

    input:
    path output_docs from ch_output_docs
    path images from ch_output_docs_images

    output:
    path "results_description.html"

    script:
    """
    markdown_to_html.py $output_docs -o results_description.html
    """
}

/*
 * Completion e-mail notification
 */
workflow.onComplete {

    // Set up the e-mail variables
    def subject = "[nf-core/viralrecon] Successful: $workflow.runName"
    if (fail_mapped_reads.size() > 0) {
        subject = "[nf-core/viralrecon] Partially Successful (${fail_mapped_reads.size()} skipped): $workflow.runName"
    }
    if (!workflow.success) {
        subject = "[nf-core/viralrecon] FAILED: $workflow.runName"
    }
    def email_fields = [:]
    email_fields['version'] = workflow.manifest.version
    email_fields['runName'] = custom_runName ?: workflow.runName
    email_fields['success'] = workflow.success
    email_fields['dateComplete'] = workflow.complete
    email_fields['duration'] = workflow.duration
    email_fields['exitStatus'] = workflow.exitStatus
    email_fields['errorMessage'] = (workflow.errorMessage ?: 'None')
    email_fields['errorReport'] = (workflow.errorReport ?: 'None')
    email_fields['commandLine'] = workflow.commandLine
    email_fields['projectDir'] = workflow.projectDir
    email_fields['summary'] = summary
    email_fields['summary']['Date Started'] = workflow.start
    email_fields['summary']['Date Completed'] = workflow.complete
    email_fields['summary']['Pipeline script file path'] = workflow.scriptFile
    email_fields['summary']['Pipeline script hash ID'] = workflow.scriptId
    if (workflow.repository) email_fields['summary']['Pipeline repository Git URL'] = workflow.repository
    if (workflow.commitId) email_fields['summary']['Pipeline repository Git Commit'] = workflow.commitId
    if (workflow.revision) email_fields['summary']['Pipeline Git branch/tag'] = workflow.revision
    email_fields['fail_mapped_reads'] = fail_mapped_reads.keySet()
    email_fields['min_mapped_reads'] = params.min_mapped_reads
    email_fields['summary']['Nextflow Version'] = workflow.nextflow.version
    email_fields['summary']['Nextflow Build'] = workflow.nextflow.build
    email_fields['summary']['Nextflow Compile Timestamp'] = workflow.nextflow.timestamp

    // On success try attach the multiqc report
    def mqc_report = null
    try {
        if (workflow.success) {
            mqc_report = ch_multiqc_report.getVal()
            if (mqc_report.getClass() == ArrayList) {
                log.warn "[nf-core/viralrecon] Found multiple reports from process 'multiqc', will use only one"
                mqc_report = mqc_report[0]
            }
        }
    } catch (all) {
        log.warn "[nf-core/viralrecon] Could not attach MultiQC report to summary email"
    }

    // Check if we are only sending emails on failure
    email_address = params.email
    if (!params.email && params.email_on_fail && !workflow.success) {
        email_address = params.email_on_fail
    }

    // Render the TXT template
    def engine = new groovy.text.GStringTemplateEngine()
    def tf = new File("$baseDir/assets/email_template.txt")
    def txt_template = engine.createTemplate(tf).make(email_fields)
    def email_txt = txt_template.toString()

    // Render the HTML template
    def hf = new File("$baseDir/assets/email_template.html")
    def html_template = engine.createTemplate(hf).make(email_fields)
    def email_html = html_template.toString()

    // Render the sendmail template
    def smail_fields = [ email: email_address, subject: subject, email_txt: email_txt, email_html: email_html, baseDir: "$baseDir", mqcFile: mqc_report, mqcMaxSize: params.max_multiqc_email_size.toBytes() ]
    def sf = new File("$baseDir/assets/sendmail_template.txt")
    def sendmail_template = engine.createTemplate(sf).make(smail_fields)
    def sendmail_html = sendmail_template.toString()

    // Send the HTML e-mail
    if (email_address) {
        try {
            if (params.plaintext_email) { throw GroovyException('Send plaintext e-mail, not HTML') }
            // Try to send HTML e-mail using sendmail
            [ 'sendmail', '-t' ].execute() << sendmail_html
            log.info "[nf-core/viralrecon] Sent summary e-mail to $email_address (sendmail)"
        } catch (all) {
            // Catch failures and try with plaintext
            [ 'mail', '-s', subject, email_address ].execute() << email_txt
            log.info "[nf-core/viralrecon] Sent summary e-mail to $email_address (mail)"
        }
    }

    // Write summary e-mail HTML to a file
    def output_d = new File("${params.outdir}/pipeline_info/")
    if (!output_d.exists()) {
        output_d.mkdirs()
    }
    def output_hf = new File(output_d, "pipeline_report.html")
    output_hf.withWriter { w -> w << email_html }
    def output_tf = new File(output_d, "pipeline_report.txt")
    output_tf.withWriter { w -> w << email_txt }

    c_green = params.monochrome_logs ? '' : "\033[0;32m";
    c_purple = params.monochrome_logs ? '' : "\033[0;35m";
    c_red = params.monochrome_logs ? '' : "\033[0;31m";
    c_reset = params.monochrome_logs ? '' : "\033[0m";

    if (pass_mapped_reads.size() > 0) {
        idx = 0
        sample_mapped = ''
        total_count = pass_mapped_reads.size() + fail_mapped_reads.size()
        for (sample in pass_mapped_reads) {
            sample_mapped += "    ${sample.key}: ${sample.value}\n"
            idx += 1
            if (idx > 5) {
                sample_mapped += "    ..see pipeline reports for full list\n"
                break
            }
        }
        //log.info "[${c_purple}nf-core/viralrecon${c_reset}] ${c_green}${pass_mapped_reads.size()}/${total_count} samples passed minimum mapped reads check\n${sample_mapped}${c_reset}"
    }
    if (fail_mapped_reads.size() > 0) {
        sample_mapped = ''
        fail_mapped_reads.each { sample, value ->
            sample_mapped += "    ${sample}: ${value}\n"
        }
        log.info "[${c_purple}nf-core/viralrecon${c_reset}] ${c_red} WARNING - ${fail_mapped_reads.size()} samples skipped due to low number of mapped reads!\n${sample_mapped}${c_reset}"
    }

    if (workflow.stats.ignoredCount > 0 && workflow.success) {
        log.info "-${c_purple}Warning, pipeline completed, but with errored process(es) ${c_reset}-"
        log.info "-${c_red}Number of ignored errored process(es) : ${workflow.stats.ignoredCount} ${c_reset}-"
        log.info "-${c_green}Number of successfully ran process(es) : ${workflow.stats.succeedCount} ${c_reset}-"
    }

    if (workflow.success) {
        log.info "-${c_purple}[nf-core/viralrecon]${c_green} Pipeline completed successfully${c_reset}-"
    } else {
        checkHostname()
        log.info "-${c_purple}[nf-core/viralrecon]${c_red} Pipeline completed with errors${c_reset}-"
    }

}

def nfcoreHeader() {
    // Log colors ANSI codes
    c_black = params.monochrome_logs ? '' : "\033[0;30m";
    c_blue = params.monochrome_logs ? '' : "\033[0;34m";
    c_cyan = params.monochrome_logs ? '' : "\033[0;36m";
    c_dim = params.monochrome_logs ? '' : "\033[2m";
    c_green = params.monochrome_logs ? '' : "\033[0;32m";
    c_purple = params.monochrome_logs ? '' : "\033[0;35m";
    c_reset = params.monochrome_logs ? '' : "\033[0m";
    c_white = params.monochrome_logs ? '' : "\033[0;37m";
    c_yellow = params.monochrome_logs ? '' : "\033[0;33m";

    return """    -${c_dim}--------------------------------------------------${c_reset}-
                                            ${c_green},--.${c_black}/${c_green},-.${c_reset}
    ${c_blue}        ___     __   __   __   ___     ${c_green}/,-._.--~\'${c_reset}
    ${c_blue}  |\\ | |__  __ /  ` /  \\ |__) |__         ${c_yellow}}  {${c_reset}
    ${c_blue}  | \\| |       \\__, \\__/ |  \\ |___     ${c_green}\\`-._,-`-,${c_reset}
                                            ${c_green}`._,._,\'${c_reset}
    ${c_purple}  nf-core/viralrecon v${workflow.manifest.version}${c_reset}
    -${c_dim}--------------------------------------------------${c_reset}-
    """.stripIndent()
}

def checkHostname() {
    def c_reset = params.monochrome_logs ? '' : "\033[0m"
    def c_white = params.monochrome_logs ? '' : "\033[0;37m"
    def c_red = params.monochrome_logs ? '' : "\033[1;91m"
    def c_yellow_bold = params.monochrome_logs ? '' : "\033[1;93m"
    if (params.hostnames) {
        def hostname = "hostname".execute().text.trim()
        params.hostnames.each { prof, hnames ->
            hnames.each { hname ->
                if (hostname.contains(hname) && !workflow.profile.contains(prof)) {
                    log.error "====================================================\n" +
                            "  ${c_red}WARNING!${c_reset} You are running with `-profile $workflow.profile`\n" +
                            "  but your machine hostname is ${c_white}'$hostname'${c_reset}\n" +
                            "  ${c_yellow_bold}It's highly recommended that you use `-profile $prof${c_reset}`\n" +
                            "============================================================"
                }
            }
        }
    }
}

// Function to check if running offline
def isOffline() {
    try {
        return NXF_OFFLINE as Boolean
    }
    catch( Exception e ) {
        return false
    }
}
