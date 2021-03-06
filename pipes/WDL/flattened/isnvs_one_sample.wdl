version 1.0



workflow isnvs_one_sample {
    meta {
        description: "Intrahost variant calling with V-Phaser2. Requires an assembled genome and a BAM of aligned reads against that same genome."
        author: "Broad Viral Genomics"
        email:  "viral-ngs@broadinstitute.org"
    }

    call intrahost__isnvs_per_sample as isnvs_per_sample

    output {
        File   isnvsFile                   = isnvs_per_sample.isnvsFile
        String isnvs_viral_phylo_version   = isnvs_per_sample.viralngs_version
    }
}



task intrahost__isnvs_per_sample {
  input {
    File    mapped_bam
    File    assembly_fasta

    Int?    threads
    Int?    minReadsPerStrand
    Int?    maxBias
    Boolean removeDoublyMappedReads=true

    Int?    machine_mem_gb
    String  docker="quay.io/broadinstitute/viral-phylo:2.1.12.0"

    String  sample_name = basename(basename(basename(mapped_bam, ".bam"), ".all"), ".mapped")
  }

  command {
    intrahost.py --version | tee VERSION
    intrahost.py vphaser_one_sample \
        ${mapped_bam} \
        ${assembly_fasta} \
        vphaser2.${sample_name}.txt.gz \
        ${'--vphaserNumThreads=' + threads} \
        ${true="--removeDoublyMappedReads" false="" removeDoublyMappedReads} \
        ${'--minReadsEach=' + minReadsPerStrand} \
        ${'--maxBias=' + maxBias}
  }

  output {
    File   isnvsFile        = "vphaser2.${sample_name}.txt.gz"
    String viralngs_version = read_string("VERSION")
  }
  runtime {
    docker: "${docker}"
    memory: select_first([machine_mem_gb, 7]) + " GB"
    dx_instance_type: "mem1_ssd1_v2_x8"
  }
}


