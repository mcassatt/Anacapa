#! /bin/bash

### this script is run as follows
# sh ~/Anacapa_db/scripts/anacapa_release_20171110.sh -i <input_dir> -o <out_dir> -d <database_directory> -u <hoffman_account_user_name> -f <fasta file of forward primers> -r <fasta file of reverse primers> -a <adapter type (nextera or truseq)>  -t <illumina run type HiSeq or MiSeq>
IN=""
OUT=""
DB=""
UN=""
FP=""
RP=""
ADPT=""
ILLTYPE=""

while getopts "i:o:d:u:f:r:a:t:" opt; do
    case $opt in
        i) IN="$OPTARG" # path to raw .fastq.gz files
        ;;
        o) OUT="$OPTARG" # path to desired Anacapa output
        ;;
        d) DB="$OPTARG"  # path to Anacapa_db
        ;;
        u) UN="$OPTARG"  # need username for submitting sequencing job
        ;;
        f) FP="$OPTARG"  # need forward reads for cutadapt
        ;;
        r) RP="$OPTARG"  # need reverse reads for cutadapt
        ;;
        a) ADPT="$OPTARG"  # need adapter for cutadapt
        ;;
        t) ILLTYPE="$OPTARG"  #need to know trim params cutadapt
        ;;
    esac
done

####################################script & software
# This pipeline was developed and written by Emily Curd (eecurd@g.ucla.edu), Jesse Gomer (jessegomer@gmail.com), Baochen Shi (biosbc@gmail.com), and Gaurav Kandlikar (gkandlikar@ucla.edu), and with contributions from Zack Gold (zack.j.gold@gmail.com), Rachel Turba (rturba@ucla.edu) and Rachel Meyer (rsmeyer@ucla.edu).
# Last Updated 11-18-2017
#
# The purpose of this script is to process raw fastq.gz files from an Illumina sequencing and generate summarized taxonomic assignment tables for multiple metabarcoding targets.
#
# This script is currently designed to run on UCLA's Hoffman2 cluster.  Please adjust the code to work with your computing resources. (e.g. module / path names to programs, submitting jobs for processing if you have a cluster, etc)
#
# This script runs in two phases, the first is the qc phase that follows the anacapa_release.  The second phase follows the run_dada2_bowtie2.sh scripts, and includes dada2 denoising, mergeing (if reads are paired) and chimera detection / bowtie2 sequence assignment phase.
#
######################################

# Need to make a script to make sure dependencies are properly configured

# location of the config and var files
source $DB/scripts/anacapa_vars_nextV.sh  # edit to change variables and parameters
source $DB/scripts/anacapa_config.sh # edit for proper configuration


##load modules / software
${MODULE_SOURCE} # use if you need to load modules from an HPC
${FASTX_TOOLKIT} #load fastx_toolkit
${ANACONDA_PYTHON} #load anaconda/python2-4.2
${PERL} #load perl
${ATS} #load ATS, Hoffman2 specific module for managing submitted jobs.
date
###

################################
# Preprocessing .fastq files
################################
echo " "
echo " "
echo "Preprocessing: 1) Generate an md5sum file"  # user can check for file corruption
md5sum ${IN}/*fastq.gz > ${IN}/*fastq.gz.md5sum  
date
###
echo "Preprocessing: 2) Rename each file for readability" # remove the additional and less relevant information in an illumna fasta file name 
###################################
suffix1=R1_001.fastq
suffix2=R2_001.fastq
###################################
mkdir -p ${OUT}
mkdir -p ${OUT}/QC
mkdir -p ${OUT}/QC/fastq
###
for str in `ls ${IN}/*_${suffix1}.gz`
do
 str1=${str%*_${suffix1}.gz}
 i=${str1#${IN}/}
 mod=${i//_/-} 
 cp ${IN}/${i}_${suffix1}.gz ${OUT}/QC/fastq/${mod}_1.fastq.gz
 cp ${IN}/${i}_${suffix2}.gz ${OUT}/QC/fastq/${mod}_2.fastq.gz
done
date
###


echo "Preprocessing: 3) Uncompress files"
gunzip ${OUT}/QC/fastq/*.fastq.gz
date
###

################################
# QC the preprocessed .fastq files
#############################

echo "QC: 1) Run cutadapt to remove 5'sequncing adapters and 3'primers + sequencing adapters, sort for length, and quality."

# Generate cut adapt primer files -> merge reverse complemented primers with adapters for cutting 3'end sequencing past the end of the metabarcode region, and add cutadapt specific characters to primers and primer/adapter combos so that the appropriate ends of reads are trimmed
mkdir -p ${OUT}/Run_info/
mkdir -p ${OUT}/Run_info/cutadapt_primers_and_adapters

echo " "
echo "Generating Primer and Primer + Adapter files for for cutadapt steps.  Your adapter type is ${ADPT}."
cp ${DB}/adapters_and_PrimAdapt_rc/*_${ADPT}_*_adapter.txt ${OUT}/Run_info/cutadapt_primers_and_adapters
python ${DB}/scripts/anacapa_format_primers_cutadapt.py ${ADPT} ${FP} ${RP} ${OUT}/Run_info/cutadapt_primers_and_adapters


# now use the formated cutadapt primer file to trim fastq reads
mkdir -p ${OUT}/QC/cutadapt_fastq
mkdir -p ${OUT}/QC/cutadapt_fastq/untrimmed
mkdir -p ${OUT}/QC/cutadapt_fastq/primer_sort
mkdir -p ${OUT}/Run_info/cutadapt_out
###
for str in `ls ${OUT}/QC/fastq/*_1.fastq`
do
 # first chop of the 5' adapter and 3' adapter and primer combo (reverse complemented)
 str1=${str%_*}
 j=${str1#${OUT}/QC/fastq/}
 echo ${j} "..."
 ${CUTADAPT} -e ${ERROR_QC1} -f ${FILE_TYPE_QC1} -g ${F_ADAPT} -a ${Rrc_PRIM_ADAPT} -G ${R_ADAPT} -A ${Frc_PRIM_ADAPT} -o ${OUT}/QC/cutadapt_fastq/untrimmed/${j}_Paired_1.fastq -p ${OUT}/QC/cutadapt_fastq/untrimmed/${j}_Paired_2.fastq ${str1}_1.fastq ${str1}_2.fastq >> ${OUT}/Run_info/cutadapt_out/cutadapt-report.txt
 # stringent quality fileter to get rid of the junky sequence at the ends - modify in config file
 fastq_quality_trimmer -t ${MIN_QUAL} -l ${MIN_LEN}  -i ${OUT}/QC/cutadapt_fastq/untrimmed/${j}_Paired_1.fastq -o ${OUT}/QC/cutadapt_fastq/${j}_qcPaired_1.fastq -Q33
 fastq_quality_trimmer -t ${MIN_QUAL} -l ${MIN_LEN}  -i ${OUT}/QC/cutadapt_fastq/untrimmed/${j}_Paired_2.fastq -o ${OUT}/QC/cutadapt_fastq/${j}_qcPaired_2.fastq -Q33
 # sort by metabarcode but run additional trimming.  It makes a differnce in merging reads in dada2.  Trimming varies based on seqeuncing platform.
 echo "forward..."
 if [ "${ILLTYPE}" == "MiSeq"  ]; # if MiSeq chop more off the end than if HiSeq - modify length in the vars file
 then
  ${CUTADAPT} -e ${ERROR_PS} -f ${FILE_TYPE_PS} -g ${F_PRIM}  -u -${MS_F_TRIM} -o ${OUT}/QC/cutadapt_fastq/primer_sort/{name}_${j}_Paired_1.fastq  ${OUT}/QC/cutadapt_fastq/${j}_qcPaired_1.fastq >> ${OUT}/Run_info/cutadapt_out/cutadapt-report.txt
  echo "check"
  echo "reverse..."
  ${CUTADAPT} -e ${ERROR_PS} -f ${FILE_TYPE_PS} -g ${R_PRIM}  -u -${MS_R_TRIM} -o ${OUT}/QC/cutadapt_fastq/primer_sort/{name}_${j}_Paired_2.fastq   ${OUT}/QC/cutadapt_fastq/${j}_qcPaired_2.fastq >> ${OUT}/Run_info/cutadapt_out/cutadapt-report.txt
  echo "check"
 else
  ${CUTADAPT} -e ${ERROR_PS} -f ${FILE_TYPE_PS} -g ${F_PRIM}  -u -${HS_F_TRIM} -o ${OUT}/QC/cutadapt_fastq/primer_sort/{name}_${j}_Paired_1.fastq  ${OUT}/QC/cutadapt_fastq/${j}_qcPaired_1.fastq >> ${OUT}/Run_info/cutadapt_out/cutadapt-report.txt
  echo "check"
  echo "reverse..."
  ${CUTADAPT} -e ${ERROR_PS} -f ${FILE_TYPE_PS} -g ${R_PRIM}  -u -${HS_R_TRIM} -o ${OUT}/QC/cutadapt_fastq/primer_sort/{name}_${j}_Paired_2.fastq   ${OUT}/QC/cutadapt_fastq/${j}_qcPaired_2.fastq >> ${OUT}/Run_info/cutadapt_out/cutadapt-report.txt
  echo "check"
 fi
 date
 echo ${j} "...  check!"
done
date
###

###############################
# Make sure unassembled reads are still paired
###############################

echo "Checking that Paired reads are still paired:"
for str in `ls ${OUT}/QC/cutadapt_fastq/primer_sort/*_*_Paired_1.fastq`
do
 str1=${str%_*_Paired_1.fastq}
 j=${str1#${OUT}/QC/cutadapt_fastq/primer_sort/}
 if [ "${j}" != "unknown"  ]; # ignore all of the unknown reads...
 then
  echo ${j} "..."
  mkdir -p ${OUT}/${j}
  mkdir -p ${OUT}/${j}/${j}_sort_by_read_type
  mkdir -p ${OUT}/${j}/${j}_sort_by_read_type/paired
  mkdir -p ${OUT}/${j}/${j}_sort_by_read_type/unpaired_F
  mkdir -p ${OUT}/${j}/${j}_sort_by_read_type/unpaired_R
 
  for st in `ls ${OUT}/QC/cutadapt_fastq/primer_sort/${j}_*_Paired_1.fastq`
	do
 	st2=${st%*_Paired_1.fastq}
 	k=${st2#${OUT}/QC/cutadapt_fastq/primer_sort/}
    python ${DB}/scripts/check_paired.py ${OUT}/QC/cutadapt_fastq/primer_sort/${j}_${k}_Paired_1.fastq ${OUT}/QC/cutadapt_fastq/primer_sort/${j}_${k}_Paired_2.fastq ${OUT}/${j}/${j}_sort_by_read_type/paired ${OUT}/${j}/${j}_sort_by_read_type/unpaired_F/ ${OUT}/${j}/${j}_sort_by_read_type/unpaired_R/
    echo ${j} "...check!" 
  done
 fi
done
date