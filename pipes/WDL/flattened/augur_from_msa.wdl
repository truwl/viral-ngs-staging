version 1.0



workflow augur_from_msa {
    meta {
        description: "Build trees, and convert to json representation suitable for Nextstrain visualization. See https://nextstrain.org/docs/getting-started/ and https://nextstrain-augur.readthedocs.io/en/stable/"
        author: "Broad Viral Genomics"
        email:  "viral-ngs@broadinstitute.org"
    }

    input {
        File            msa_or_vcf
        File            sample_metadata
        File            ref_fasta
        File            genbank_gb
        File            auspice_config
        File?           clades_tsv
        Array[String]?  ancestral_traits_to_infer
    }

    parameter_meta {
        msa_or_vcf: {
          description: "Multiple sequence alignment (aligned fasta) or variants (vcf format).",
          patterns: ["*.fasta", "*.fa", "*.vcf", "*.vcf.gz"]
        }
        sample_metadata: {
          description: "Metadata in tab-separated text format. See https://nextstrain-augur.readthedocs.io/en/stable/faq/metadata.html for details.",
          patterns: ["*.txt", "*.tsv"]
        }
        ref_fasta: {
          description: "A reference assembly (not included in assembly_fastas) to align assembly_fastas against. Typically from NCBI RefSeq or similar.",
          patterns: ["*.fasta", "*.fa"]
        }
        genbank_gb: {
          description: "A 'genbank' formatted gene annotation file that is used to calculate coding consequences of observed mutations. Must correspond to the same coordinate space as ref_fasta. Typically downloaded from the same NCBI accession number as ref_fasta.",
          patterns: ["*.gb", "*.gbf"]
        }
        ancestral_traits_to_infer: {
          description: "A list of metadata traits to use for ancestral node inference (see https://nextstrain-augur.readthedocs.io/en/stable/usage/cli/traits.html). Multiple traits may be specified; must correspond exactly to column headers in metadata file. Omitting these values will skip ancestral trait inference, and ancestral nodes will not have estimated values for metadata."
        }
        auspice_config: {
          description: "A file specifying options to customize the auspice export; see: https://nextstrain.github.io/auspice/customise-client/introduction",
          patterns: ["*.json", "*.txt"]
        }
        clades_tsv: {
          description: "A TSV file containing clade mutation positions in four columns: [clade  gene    site    alt]; see: https://nextstrain.org/docs/tutorials/defining-clades",
          patterns: ["*.tsv", "*.txt"]
        }
    }

    call nextstrain__filter_sequences_to_list as filter_sequences_to_list {
        input:
            sequences = msa_or_vcf
    }
    call nextstrain__augur_mask_sites as augur_mask_sites {
        input:
            sequences = filter_sequences_to_list.filtered_fasta
    }
    call nextstrain__draft_augur_tree as draft_augur_tree {
        input:
            msa_or_vcf = augur_mask_sites.masked_sequences
    }
    call nextstrain__refine_augur_tree as refine_augur_tree {
        input:
            raw_tree    = draft_augur_tree.aligned_tree,
            msa_or_vcf  = augur_mask_sites.masked_sequences,
            metadata    = sample_metadata
    }
    if(defined(ancestral_traits_to_infer) && length(select_first([ancestral_traits_to_infer,[]]))>0) {
        call nextstrain__ancestral_traits as ancestral_traits {
            input:
                tree           = refine_augur_tree.tree_refined,
                metadata       = sample_metadata,
                columns        = select_first([ancestral_traits_to_infer,[]])
        }
    }
    call nextstrain__ancestral_tree as ancestral_tree {
        input:
            tree        = refine_augur_tree.tree_refined,
            msa_or_vcf  = augur_mask_sites.masked_sequences
    }
    call nextstrain__translate_augur_tree as translate_augur_tree {
        input:
            tree        = refine_augur_tree.tree_refined,
            nt_muts     = ancestral_tree.nt_muts_json,
            genbank_gb  = genbank_gb
    }
    if(defined(clades_tsv)) {
        call nextstrain__assign_clades_to_nodes as assign_clades_to_nodes {
            input:
                tree_nwk     = refine_augur_tree.tree_refined,
                nt_muts_json = ancestral_tree.nt_muts_json,
                aa_muts_json = translate_augur_tree.aa_muts_json,
                ref_fasta    = ref_fasta,
                clades_tsv   = select_first([clades_tsv])
        }
    }
    call nextstrain__export_auspice_json as export_auspice_json {
        input:
            tree            = refine_augur_tree.tree_refined,
            sample_metadata = sample_metadata,
            node_data_jsons = select_all([
                                refine_augur_tree.branch_lengths,
                                ancestral_traits.node_data_json,
                                ancestral_tree.nt_muts_json,
                                translate_augur_tree.aa_muts_json,
                                assign_clades_to_nodes.node_clade_data_json]),
            auspice_config  = auspice_config
    }

    output {
        File  masked_alignment    = augur_mask_sites.masked_sequences
        File  ml_tree             = draft_augur_tree.aligned_tree
        File  time_tree           = refine_augur_tree.tree_refined
        File  auspice_input_json  = export_auspice_json.virus_json
    }
}


task nextstrain__filter_sequences_to_list {
    meta {
        description: "Filter and subsample a sequence set to a specific list of ids in a text file (one id per line)."
    }
    input {
        File          sequences
        Array[File]?  keep_list

        String   docker = "nextstrain/base:build-20200629T201240Z"
    }
    parameter_meta {
        sequences: {
          description: "Set of sequences (unaligned fasta or aligned fasta -- one sequence per genome) or variants (vcf format) to subsample using augur filter.",
          patterns: ["*.fasta", "*.fa", "*.vcf", "*.vcf.gz"]
        }
        keep_list: {
          description: "List of strain ids.",
          patterns: ["*.txt", "*.tsv"]
        }
    }
    String out_fname = sub(sub(basename(sequences), ".vcf", ".filtered.vcf"), ".fasta$", ".filtered.fasta")
    Int mem_size = ceil(size(sequences, "GB") * 2 + 0.001)
    command {
        set -e
        augur version > VERSION
        KEEP_LISTS="~{sep=' ' select_first([keep_list, []])}"

        if [ -n "$KEEP_LISTS" ]; then
            echo "strain" > keep_list.txt
            cat $KEEP_LISTS >> keep_list.txt
            augur filter \
                --sequences "~{sequences}" \
                --metadata keep_list.txt \
                --output "~{out_fname}" | tee STDOUT
            grep "sequences were dropped during filtering" STDOUT | cut -f 1 -d ' ' > DROP_COUNT
            grep "sequences have been written out to" STDOUT | cut -f 1 -d ' ' > OUT_COUNT
        else
            cp "~{sequences}" "~{out_fname}"
            echo "0" > DROP_COUNT
            echo "-1" > OUT_COUNT
        fi
        cat /proc/uptime | cut -f 1 -d ' ' > UPTIME_SEC
        cat /proc/loadavg > CPU_LOAD
        cat /sys/fs/cgroup/memory/memory.max_usage_in_bytes > MEM_BYTES
    }
    runtime {
        docker: docker
        memory: mem_size + " GB"
        cpu :   2
        disks:  "local-disk 100 HDD"
        dx_instance_type: "mem1_ssd1_v2_x2"
        preemptible: 1
    }
    output {
        File   filtered_fasta    = out_fname
        String augur_version     = read_string("VERSION")
        Int    sequences_dropped = read_int("DROP_COUNT")
        Int    sequences_out     = read_int("OUT_COUNT")
        Int    max_ram_gb = ceil(read_float("MEM_BYTES")/1000000000)
        Int    runtime_sec = ceil(read_float("UPTIME_SEC"))
        String cpu_load = read_string("CPU_LOAD")
    }
}




task nextstrain__augur_mask_sites {
    meta {
        description: "Mask unwanted positions from alignment or SNP table. See https://nextstrain-augur.readthedocs.io/en/stable/usage/cli/mask.html"
    }
    input {
        File     sequences
        File?    mask_bed

        String   docker = "nextstrain/base:build-20200629T201240Z"
    }
    parameter_meta {
        sequences: {
          description: "Set of alignments (fasta format) or variants (vcf format) to mask.",
          patterns: ["*.fasta", "*.fa", "*.vcf", "*.vcf.gz"]
        }
    }
    String out_fname = sub(sub(basename(sequences), ".vcf", ".masked.vcf"), ".fasta$", ".masked.fasta")
    command {
        set -e
        augur version > VERSION
        BEDFILE=~{select_first([mask_bed, "/dev/null"])}
        if [ -s "$BEDFILE" ]; then
            augur mask --sequences "~{sequences}" \
                --mask "$BEDFILE" \
                --output "~{out_fname}"
        else
            cp "~{sequences}" "~{out_fname}"
        fi
        cat /proc/uptime | cut -f 1 -d ' ' > UPTIME_SEC
        cat /proc/loadavg > CPU_LOAD
        cat /sys/fs/cgroup/memory/memory.max_usage_in_bytes > MEM_BYTES
    }
    runtime {
        docker: docker
        memory: "3 GB"
        cpu :   4
        disks:  "local-disk 100 HDD"
        preemptible: 1
        dx_instance_type: "mem1_ssd1_v2_x4"
    }
    output {
        File   masked_sequences = out_fname
        Int    max_ram_gb = ceil(read_float("MEM_BYTES")/1000000000)
        Int    runtime_sec = ceil(read_float("UPTIME_SEC"))
        String cpu_load = read_string("CPU_LOAD")
        String augur_version  = read_string("VERSION")
    }
}




task nextstrain__draft_augur_tree {
    meta {
        description: "Build a tree using iqTree. See https://nextstrain-augur.readthedocs.io/en/stable/usage/cli/tree.html"
    }
    input {
        File     msa_or_vcf

        String   method = "iqtree"
        String   substitution_model = "GTR"
        File?    exclude_sites
        File?    vcf_reference
        String?  tree_builder_args

        Int?     cpus
        String   docker = "nextstrain/base:build-20200629T201240Z"
    }
    parameter_meta {
        msa_or_vcf: {
          description: "Set of alignments (fasta format) or variants (vcf format) to construct a tree from using augur tree (iqTree).",
          patterns: ["*.fasta", "*.fa", "*.vcf", "*.vcf.gz"]
        }
    }
    String out_basename = basename(basename(basename(msa_or_vcf, '.gz'), '.vcf'), '.fasta')
    command {
        set -e
        augur version > VERSION
        AUGUR_RECURSION_LIMIT=10000 augur tree --alignment "~{msa_or_vcf}" \
            --output "~{out_basename}_~{method}.nwk" \
            --method "~{method}" \
            --substitution-model ~{default="GTR" substitution_model} \
            ~{"--exclude-sites " + exclude_sites} \
            ~{"--vcf-reference " + vcf_reference} \
            ~{"--tree-builder-args " + tree_builder_args} \
            --nthreads auto
        cat /proc/uptime | cut -f 1 -d ' ' > UPTIME_SEC
        cat /proc/loadavg > CPU_LOAD
        cat /sys/fs/cgroup/memory/memory.max_usage_in_bytes > MEM_BYTES
    }
    runtime {
        docker: docker
        memory: "32 GB"
        cpu:    select_first([cpus, 64])
        disks:  "local-disk 750 LOCAL"
        dx_instance_type: "mem1_ssd1_v2_x36"
        preemptible: 0
    }
    output {
        File   aligned_tree = "~{out_basename}_~{method}.nwk"
        Int    max_ram_gb = ceil(read_float("MEM_BYTES")/1000000000)
        Int    runtime_sec = ceil(read_float("UPTIME_SEC"))
        String cpu_load = read_string("CPU_LOAD")
        String augur_version = read_string("VERSION")
    }
}




task nextstrain__refine_augur_tree {
    meta {
        description: "Refine an initial tree using sequence metadata and Treetime. See https://nextstrain-augur.readthedocs.io/en/stable/usage/cli/refine.html"
    }
    input {
        File     raw_tree
        File     msa_or_vcf
        File     metadata

        Int?     gen_per_year
        Float?   clock_rate
        Float?   clock_std_dev
        Boolean  keep_root = false
        String?  root
        Boolean? covariance
        Boolean  keep_polytomies = false
        Int?     precision
        Boolean  date_confidence = true
        String?  date_inference = "marginal"
        String?  branch_length_inference
        String?  coalescent
        Int?     clock_filter_iqd = 4
        String?  divergence_units
        File?    vcf_reference

        String   docker = "nextstrain/base:build-20200629T201240Z"
    }
    parameter_meta {
        msa_or_vcf: {
          description: "Set of alignments (fasta format) or variants (vcf format) to use to guide Treetime.",
          patterns: ["*.fasta", "*.fa", "*.vcf", "*.vcf.gz"]
        }
    }
    String out_basename = basename(basename(basename(msa_or_vcf, '.gz'), '.vcf'), '.fasta')
    command {
        set -e
        augur version > VERSION
        AUGUR_RECURSION_LIMIT=10000 augur refine \
            --tree "~{raw_tree}" \
            --alignment "~{msa_or_vcf}" \
            --metadata "~{metadata}" \
            --output-tree "~{out_basename}_timetree.nwk" \
            --output-node-data "~{out_basename}_branch_lengths.json" \
            --timetree \
            ~{"--clock-rate " + clock_rate} \
            ~{"--clock-std-dev " + clock_std_dev} \
            ~{"--coalescent " + coalescent} \
            ~{"--clock-filter-iqd " + clock_filter_iqd} \
            ~{"--gen-per-year " + gen_per_year} \
            ~{"--root " + root} \
            ~{"--precision " + precision} \
            ~{"--date-inference " + date_inference} \
            ~{"--branch-length-inference " + branch_length_inference} \
            ~{"--divergence-units " + divergence_units} \
            ~{true="--covariance" false="--no-covariance" covariance} \
            ~{true="--keep-root" false="" keep_root} \
            ~{true="--keep-polytomies" false="" keep_polytomies} \
            ~{true="--date-confidence" false="" date_confidence} \
            ~{"--vcf-reference " + vcf_reference}
        cat /proc/uptime | cut -f 1 -d ' ' > UPTIME_SEC
        cat /proc/loadavg > CPU_LOAD
        cat /sys/fs/cgroup/memory/memory.max_usage_in_bytes > MEM_BYTES
    }
    runtime {
        docker: docker
        memory: "50 GB"
        cpu :   2
        disks:  "local-disk 100 HDD"
        dx_instance_type: "mem3_ssd1_v2_x8"
        preemptible: 0
    }
    output {
        File   tree_refined  = "~{out_basename}_timetree.nwk"
        File   branch_lengths = "~{out_basename}_branch_lengths.json"
        Int    max_ram_gb = ceil(read_float("MEM_BYTES")/1000000000)
        Int    runtime_sec = ceil(read_float("UPTIME_SEC"))
        String cpu_load = read_string("CPU_LOAD")
        String augur_version = read_string("VERSION")
    }
}




task nextstrain__ancestral_traits {
    meta {
        description: "Infer ancestral traits based on a tree. See https://nextstrain-augur.readthedocs.io/en/stable/usage/cli/traits.html"
    }
    input {
        File           tree
        File           metadata
        Array[String]  columns

        Boolean        confidence = true
        File?          weights
        Float?         sampling_bias_correction

        String   docker = "nextstrain/base:build-20200629T201240Z"
    }
    String out_basename = basename(tree, '.nwk')
    command {
        set -e
        augur version > VERSION
        AUGUR_RECURSION_LIMIT=10000 augur traits \
            --tree "~{tree}" \
            --metadata "~{metadata}" \
            --columns ~{sep=" " columns} \
            --output-node-data "~{out_basename}_ancestral_traits.json" \
            ~{"--weights " + weights} \
            ~{"--sampling-bias-correction " + sampling_bias_correction} \
            ~{true="--confidence" false="" confidence}
        cat /proc/uptime | cut -f 1 -d ' ' > UPTIME_SEC
        cat /proc/loadavg > CPU_LOAD
        cat /sys/fs/cgroup/memory/memory.max_usage_in_bytes > MEM_BYTES
    }
    runtime {
        docker: docker
        memory: "3 GB"
        cpu :   2
        disks:  "local-disk 50 HDD"
        dx_instance_type: "mem1_ssd1_v2_x2"
        preemptible: 1
    }
    output {
        File   node_data_json = "~{out_basename}_ancestral_traits.json"
        Int    max_ram_gb = ceil(read_float("MEM_BYTES")/1000000000)
        Int    runtime_sec = ceil(read_float("UPTIME_SEC"))
        String cpu_load = read_string("CPU_LOAD")
        String augur_version = read_string("VERSION")
    }
}




task nextstrain__ancestral_tree {
    meta {
        description: "Infer ancestral sequences based on a tree. See https://nextstrain-augur.readthedocs.io/en/stable/usage/cli/ancestral.html"
    }
    input {
        File     tree
        File     msa_or_vcf

        String   inference = "joint"
        Boolean  keep_ambiguous = false
        Boolean  infer_ambiguous = false
        Boolean  keep_overhangs = false
        File?    vcf_reference
        File?    output_vcf

        String   docker = "nextstrain/base:build-20200629T201240Z"
    }
    parameter_meta {
        msa_or_vcf: {
          description: "Set of alignments (fasta format) or variants (vcf format) to use to guide Treetime.",
          patterns: ["*.fasta", "*.fa", "*.vcf", "*.vcf.gz"]
        }
    }
    String out_basename = basename(basename(basename(msa_or_vcf, '.gz'), '.vcf'), '.fasta')
    command {
        set -e
        augur version > VERSION
        AUGUR_RECURSION_LIMIT=10000 augur ancestral \
            --tree "~{tree}" \
            --alignment "~{msa_or_vcf}" \
            --output-node-data "~{out_basename}_nt_muts.json" \
            ~{"--vcf-reference " + vcf_reference} \
            ~{"--output-vcf " + output_vcf} \
            --output-sequences "~{out_basename}_ancestral_sequences.fasta" \
            ~{true="--keep-overhangs" false="" keep_overhangs} \
            --inference ~{default="joint" inference} \
            ~{true="--keep-ambiguous" false="" keep_ambiguous} \
            ~{true="--infer-ambiguous" false="" infer_ambiguous}
        cat /proc/uptime | cut -f 1 -d ' ' > UPTIME_SEC
        cat /proc/loadavg > CPU_LOAD
        cat /sys/fs/cgroup/memory/memory.max_usage_in_bytes > MEM_BYTES
    }
    runtime {
        docker: docker
        memory: "50 GB"
        cpu :   4
        disks:  "local-disk 50 HDD"
        dx_instance_type: "mem3_ssd1_v2_x8"
        preemptible: 0
    }
    output {
        File   nt_muts_json = "~{out_basename}_nt_muts.json"
        File   sequences    = "~{out_basename}_ancestral_sequences.fasta"
        Int    max_ram_gb = ceil(read_float("MEM_BYTES")/1000000000)
        Int    runtime_sec = ceil(read_float("UPTIME_SEC"))
        String cpu_load = read_string("CPU_LOAD")
        String augur_version = read_string("VERSION")
    }
}




task nextstrain__translate_augur_tree {
    meta {
        description: "export augur files to json suitable for auspice visualization. See https://nextstrain-augur.readthedocs.io/en/stable/usage/cli/translate.html"
    }
    input {
        File   tree
        File   nt_muts
        File   genbank_gb

        File?  genes
        File?  vcf_reference_output
        File?  vcf_reference

        String docker = "nextstrain/base:build-20200629T201240Z"
    }
    String out_basename = basename(tree, '.nwk')
    command {
        set -e
        augur version > VERSION
        AUGUR_RECURSION_LIMIT=10000 augur translate --tree "~{tree}" \
            --ancestral-sequences "~{nt_muts}" \
            --reference-sequence "~{genbank_gb}" \
            ~{"--vcf-reference-output " + vcf_reference_output} \
            ~{"--vcf-reference " + vcf_reference} \
            ~{"--genes " + genes} \
            --output-node-data ~{out_basename}_aa_muts.json
        cat /sys/fs/cgroup/memory/memory.max_usage_in_bytes > MEM_BYTES
    }
    runtime {
        docker: docker
        memory: "2 GB"
        cpu :   1
        disks:  "local-disk 50 HDD"
        dx_instance_type: "mem1_ssd1_v2_x2"
        preemptible: 1
    }
    output {
        File   aa_muts_json = "~{out_basename}_aa_muts.json"
        Int    max_ram_gb = ceil(read_float("MEM_BYTES")/1000000000)
        String augur_version = read_string("VERSION")
    }
}




task nextstrain__assign_clades_to_nodes {
    meta {
        description: "Assign taxonomic clades to tree nodes based on mutation information"
    }
    input {
        File tree_nwk
        File nt_muts_json
        File aa_muts_json
        File ref_fasta
        File clades_tsv

        String docker = "nextstrain/base:build-20200629T201240Z"
    }
    String out_basename = basename(basename(tree_nwk, ".nwk"), "_timetree")
    command {
        set -e
        augur version > VERSION
        AUGUR_RECURSION_LIMIT=10000 augur clades \
        --tree "~{tree_nwk}" \
        --mutations "~{nt_muts_json}" "~{aa_muts_json}" \
        --reference "~{ref_fasta}" \
        --clades "~{clades_tsv}" \
        --output-node-data "~{out_basename}_clades.json"
        cat /sys/fs/cgroup/memory/memory.max_usage_in_bytes > MEM_BYTES
    }
    runtime {
        docker: docker
        memory: "2 GB"
        cpu :   1
        disks:  "local-disk 50 HDD"
        dx_instance_type: "mem1_ssd1_v2_x2"
        preemptible: 1
    }
    output {
        File   node_clade_data_json = "~{out_basename}_clades.json"
        Int    max_ram_gb = ceil(read_float("MEM_BYTES")/1000000000)
        String augur_version      = read_string("VERSION")
    }
}




task nextstrain__export_auspice_json {
    meta {
        description: "export augur files to json suitable for auspice visualization. The metadata tsv input is generally required unless the node_data_jsons comprehensively capture all of it. See https://nextstrain-augur.readthedocs.io/en/stable/usage/cli/export.html"
    }
    input {
        File        auspice_config
        File?       sample_metadata
        File        tree
        Array[File] node_data_jsons

        File?          lat_longs_tsv
        File?          colors_tsv
        Array[String]? geo_resolutions
        Array[String]? color_by_metadata
        File?          description_md
        Array[String]? maintainers
        String?        title

        String docker = "nextstrain/base:build-20200629T201240Z"
    }
    String out_basename = basename(basename(tree, ".nwk"), "_timetree")
    command {
        set -e -o pipefail
        augur version > VERSION
        touch exportargs

        # --node-data
        if [ -n "~{sep=' ' node_data_jsons}" ]; then
            echo "--node-data" >> exportargs
            cat "~{write_lines(node_data_jsons)}" >> exportargs
        fi

        # --geo-resolutions
        VALS="~{write_lines(select_first([geo_resolutions, []]))}"
        if [ -n "$(cat $VALS)" ]; then
            echo "--geo-resolutions" >> exportargs;
        fi
        cat $VALS >> exportargs

        # --color-by-metadata
        VALS="~{write_lines(select_first([color_by_metadata, []]))}"
        if [ -n "$(cat $VALS)" ]; then
            echo "--color-by-metadata" >> exportargs;
        fi
        cat $VALS >> exportargs

        # --title
        if [ -n "~{title}" ]; then
            echo "--title" >> exportargs
            echo "~{title}" >> exportargs
        fi

        # --maintainers
        VALS="~{write_lines(select_first([maintainers, []]))}"
        if [ -n "$(cat $VALS)" ]; then
            echo "--maintainers" >> exportargs;
        fi
        cat $VALS >> exportargs

        (export AUGUR_RECURSION_LIMIT=10000; cat exportargs | tr '\n' '\0' | xargs -0 -t augur export v2 \
            --tree "~{tree}" \
            ~{"--metadata " + sample_metadata} \
            --auspice-config "~{auspice_config}" \
            ~{"--lat-longs " + lat_longs_tsv} \
            ~{"--colors " + colors_tsv} \
            ~{"--description " + description_md} \
            --output "~{out_basename}_auspice.json")
        cat /proc/uptime | cut -f 1 -d ' ' > UPTIME_SEC
        cat /proc/loadavg > CPU_LOAD
        cat /sys/fs/cgroup/memory/memory.max_usage_in_bytes > MEM_BYTES
    }
    runtime {
        docker: docker
        memory: "3 GB"
        cpu :   2
        disks:  "local-disk 100 HDD"
        dx_instance_type: "mem1_ssd1_v2_x2"
        preemptible: 0
    }
    output {
        File   virus_json = "~{out_basename}_auspice.json"
        Int    max_ram_gb = ceil(read_float("MEM_BYTES")/1000000000)
        Int    runtime_sec = ceil(read_float("UPTIME_SEC"))
        String cpu_load = read_string("CPU_LOAD")
        String augur_version = read_string("VERSION")
    }
}


