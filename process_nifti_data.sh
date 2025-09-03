#!/bin/bash
# Directory dove si trovano i file NIfTI convertiti
NIFTI_DIR="/nifti"
# Directory dove salvare gli output di TotalSegmentator
OUTPUT_TS_DIR="/output_ts"
# Log file
LOG_FILE="/var/log/totalseg_processing.log"

# Funzione per logging
log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] TotalSegmentator: $1" | tee -a "$LOG_FILE"
}

# Funzione per processare un file NIfTI con TotalSegmentator
process_nifti_with_totalseg() {
    local nifti_series_dir="$1" # La directory della serie NIfTI (es. /nifti/studyID/seriesID)
    local input_nii="${nifti_series_dir}/series.nii"
    
    # Estrai il percorso relativo rispetto a NIFTI_DIR
    local rel_path="${nifti_series_dir#$NIFTI_DIR/}"
    local output_ts_series_dir="${OUTPUT_TS_DIR}/${rel_path}"
    
    # DEFINIAMO IL PERCORSO CORRETTO PER IL FLAG .processed_ts
    local processed_ts_file="${output_ts_series_dir}/.processed_ts"
    
    # Verifica se il file NIfTI esiste
    if [ ! -f "$input_nii" ]; then
        log_message "File NIfTI non trovato, saltando: $input_nii"
        return
    fi
    
    # Verifica se la serie è già stata processata da TotalSegmentator (cercando il flag nel posto CORRETTO)
    if [ -f "$processed_ts_file" ]; then
        log_message "Serie già processata da TotalSegmentator, saltando: $input_nii"
        return
    fi
    
    log_message "Avvio segmentazione con TotalSegmentator per: $input_nii"
    log_message "Salvando output in: $output_ts_series_dir"
    
    # Crea la directory di destinazione se non esiste
    mkdir -p "$output_ts_series_dir"
    
    # Per eseguire tutti i modelli al posto di --fast utilizzare il flag -ta total
    TotalSegmentator -i "$input_nii" -o "$output_ts_series_dir" --fast --nr_thr_resamp 1 --nr_thr_saving 1
    
    if [ $? -eq 0 ]; then
        log_message "Segmentazione completata con successo per: $input_nii"
        
        # DECOMPRIMI TUTTI I FILE .nii.gz IN .nii
        log_message "Decomprimendo file .nii.gz in .nii per: $output_ts_series_dir"
        
        # Conta i file .nii.gz prima della decompressione
        local gz_count=$(find "$output_ts_series_dir" -name "*.nii.gz" -type f | wc -l)
        
        if [ "$gz_count" -gt 0 ]; then
            log_message "Trovati $gz_count file .nii.gz da decomprimere"
            
            # Decomprimi tutti i file .nii.gz ricorsivamente
            find "$output_ts_series_dir" -name "*.nii.gz" -type f -exec gunzip {} \;
            
            # Verifica che la decompressione sia andata a buon fine
            local remaining_gz=$(find "$output_ts_series_dir" -name "*.nii.gz" -type f | wc -l)
            local nii_count=$(find "$output_ts_series_dir" -name "*.nii" -type f | wc -l)
            
            if [ "$remaining_gz" -eq 0 ] && [ "$nii_count" -gt 0 ]; then
                log_message "Decompressione completata: $nii_count file .nii creati"
            else
                log_message "Attenzione: potrebbero esserci problemi con la decompressione (rimanenti .gz: $remaining_gz, .nii: $nii_count)"
            fi
        else
            log_message "Nessun file .nii.gz trovato da decomprimere"
        fi
        
        # CREA IL FLAG .processed_ts NELLA DIRECTORY DI OUTPUT DI TOTALSEGMENTATOR
        echo "Processato con TotalSegmentator: $(date)" > "$processed_ts_file"
        log_message "Processo completato per: $input_nii"
    else
        log_message "Errore durante la segmentazione con TotalSegmentator per: $input_nii"
    fi
}

# Funzione principale per monitorare e processare
monitor_and_process_nifti() {
    log_message "Avvio monitoraggio e elaborazione NIfTI con TotalSegmentator..."
    
    # Assicurati che le directory di output esistano
    mkdir -p "$OUTPUT_TS_DIR"
    mkdir -p "$(dirname "$LOG_FILE")"
    
    while true; do
        # Trova tutte le directory di serie NIfTI che hanno un file .converted
        # Ora la logica di controllo del .processed_ts deve cercare nel posto corretto
        while IFS= read -r converted_file; do
            local nifti_series_dir=$(dirname "$converted_file")
            # Costruisci il percorso corretto per il flag .processed_ts in base alla directory di output
            local rel_path_for_ts="${nifti_series_dir#$NIFTI_DIR/}"
            local processed_ts_file_check="${OUTPUT_TS_DIR}/${rel_path_for_ts}/.processed_ts"
            
            if [ -f "$nifti_series_dir/series.nii" ] && [ ! -f "$processed_ts_file_check" ]; then
                process_nifti_with_totalseg "$nifti_series_dir"
            fi
        done < <(find "$NIFTI_DIR" -name ".converted" -type f)
        
        log_message "Attendo 30 secondi prima di cercare nuovi file NIfTI da processare..."
        sleep 30
    done
}

# Avvia il processo di monitoraggio e elaborazione
monitor_and_process_nifti