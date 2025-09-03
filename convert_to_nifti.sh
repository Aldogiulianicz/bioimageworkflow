#!/bin/bash


# Questo comando assicura che lo script termini immediatamente se un comando fallisce.
set -e


# Directory principale dove si trovano i dati DICOM scaricati (dentro il container)
DOWNLOAD_DIR="/download"
# Directory dove salvare i file NIfTI convertiti (dentro il container)
NIFTI_DIR="/nifti"
# Comando plastimatch (assicurati che sia nel PATH del container o specifica il percorso completo)
PLASTIMATCH_CMD="plastimatch"


# File di log per questo script
LOG_FILE="/var/log/dicom_conversion.log"


# Funzione per scrivere messaggi nel log e stamparli a console
log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}


# --- Inizio della logica principale ---


# Verifica che plastimatch sia installato e accessibile
if ! command -v "$PLASTIMATCH_CMD" &> /dev/null; then
    log_message "Errore: plastimatch non trovato. Assicurati che sia installato e nel PATH."
    exit 1
fi


# Funzione per convertire una singola serie DICOM in NIfTI
convert_series() {
    local series_dir="$1" # Percorso completo alla directory della serie DICOM (es: /download/paziente/studio/serie)
   
    # Estrae il percorso relativo della serie rispetto a DOWNLOAD_DIR.
    # Esempio: se series_dir è /download/P1/S1 e DOWNLOAD_DIR è /download, rel_path sarà P1/S1
    local rel_path="${series_dir#$DOWNLOAD_DIR/}"
   
    # Costruisce il percorso completo della directory di destinazione NIfTI, mantenendo la struttura.
    # Esempio: /nifti/P1/S1
    local nifti_series_dir="${NIFTI_DIR}/${rel_path}"
   
    # Definisce il nome del file NIfTI di output.
    local nifti_output="${nifti_series_dir}/series.nii"
   
    # Definisce il percorso del file di flag .done (creato dallo script di download)
    local done_file="${series_dir}/.done"
   
    # Definisce il percorso del file di flag .converted (creato da questo script, nella directory NIfTI)
    # Questa è la CORREZIONE CRUCIALE: il .converted deve stare nella directory NIfTI!
    local converted_file="${nifti_series_dir}/.converted"
   
    log_message "DEBUG: Processing series_dir: $series_dir"
    log_message "DEBUG: Expected nifti_series_dir: $nifti_series_dir"
    log_message "DEBUG: Expected nifti_output: $nifti_output"
    log_message "DEBUG: Expected done_file: $done_file"
    log_message "DEBUG: Expected converted_file: $converted_file"




    # 1. Verifica che la serie DICOM sia stata completamente scaricata.
    if [ ! -f "$done_file" ]; then
        log_message "Skipping: Serie non completamente scaricata (manca $done_file): $series_dir"
        return # Esce dalla funzione
    fi
   
    # 2. Verifica se la serie è già stata convertita in NIfTI.
    if [ -f "$converted_file" ]; then
        log_message "Skipping: Serie già convertita (trovato $converted_file): $nifti_series_dir"
        return # Esce dalla funzione
    fi
   
    # Crea la directory di destinazione per i file NIfTI se non esiste
    log_message "Creating output NIfTI directory: $nifti_series_dir"
    mkdir -p "$nifti_series_dir"
   
    # 3. Gestisce il caso in cui il file NIfTI esista già ma manchi il flag .converted
    if [ -f "$nifti_output" ]; then
        log_message "File NIfTI già esistente: $nifti_output. Marcando la serie come convertita."
        echo "Conversione completata: $(date)" > "$converted_file" # Crea il flag .converted
        if [ $? -eq 0 ] && [ -f "$converted_file" ]; then
            log_message "SUCCESS: .converted file created successfully for existing NIfTI: $converted_file"
        else
            log_message "ERROR: Failed to create .converted file for existing NIfTI: $converted_file. Check permissions or disk space."
        fi
        # Copia il .done file nella directory NIfTI per consistenza
        cp "$done_file" "${nifti_series_dir}/"
        return # Esce dalla funzione
    fi
   
    # Se il file NIfTI non esiste, procede con la conversione
    log_message "Starting conversion from DICOM: $series_dir"
    log_message "Output NIfTI will be saved to: $nifti_output"
   
    # Esegue la conversione utilizzando plastimatch.
    # Reindirizziamo stderr (2) a stdout (1) e poi a tee per catturare tutti i log di plastimatch.
    $PLASTIMATCH_CMD convert --input "$series_dir" --output-img "$nifti_output" 2>&1 | tee -a "$LOG_FILE"
   
    # 4. Verifica se la conversione con plastimatch è riuscita e il file NIfTI è stato creato
    if [ $? -eq 0 ] && [ -f "$nifti_output" ]; then
        log_message "Conversion completed successfully: $nifti_output"
       
        # Crea il flag .converted per indicare il successo
        log_message "Creating .converted file: $converted_file"
        echo "Conversione completata: $(date)" > "$converted_file"
        if [ $? -eq 0 ] && [ -f "$converted_file" ]; then
            log_message "SUCCESS: .converted file created after new conversion."
        else
            log_message "ERROR: Failed to create .converted file after new conversion: $converted_file. Check permissions or disk space."
        fi
       
        # Copia il .done file nella directory NIfTI per consistenza
        cp "$done_file" "${nifti_series_dir}/"
        log_message "Copied .done file to NIfTI directory: ${nifti_series_dir}/.done"
       
        # Estrai e salva i metadati DICOM
        log_message "Extracting DICOM metadata for: $series_dir"
        first_dicom=$(find "$series_dir" -name "*.dcm" | head -n 1) # Trova il primo file .dcm
       
        if [ -n "$first_dicom" ]; then
            # Tenta di usare dcmdump o gdcmdump per estrarre i metadati
            if command -v dcmdump &> /dev/null; then
                log_message "Using dcmdump for metadata extraction."
                dcmdump "$first_dicom" > "${nifti_series_dir}/dicom_metadata.txt" 2>&1 || log_message "WARNING: dcmdump failed to extract metadata."
            elif command -v gdcmdump &> /dev/null; then
                log_message "Using gdcmdump for metadata extraction."
                gdcmdump "$first_dicom" > "${nifti_series_dir}/dicom_metadata.txt" 2>&1 || log_message "WARNING: gdcmdump failed to extract metadata."
            else
                log_message "WARNING: No DICOM metadata tool (dcmdump/gdcmdump) found. Skipping metadata extraction."
            fi
        else
            log_message "WARNING: No DICOM files (.dcm) found in $series_dir to extract metadata from."
        fi
    else
        log_message "ERROR: Plastimatch conversion failed or NIfTI output file not found: $series_dir"
        log_message "Plastimatch exit code: $?"
    fi
}


# Funzione principale che coordina la ricerca e la conversione delle serie
main() {
    log_message "Avvio del processo di conversione DICOM a NIfTI con Plastimatch..."
   
    # Assicurati che la directory di output NIfTI principale esista
    mkdir -p "$NIFTI_DIR"
   
    # Trova tutte le directory di serie DICOM che hanno un file .done
    # Usa process substitution (`< <(...)`) per gestire correttamente gli spazi nei nomi di file/directory.
    while IFS= read -r done_file; do
        series_dir=$(dirname "$done_file") # Ottiene il percorso della directory padre del .done
        convert_series "$series_dir"
    done < <(find "$DOWNLOAD_DIR" -name ".done" -type f) # Cerca i file .done a partire da DOWNLOAD_DIR
   
    log_message "Processo di conversione completato per questo ciclo."
}


# Funzione per eseguire continuamente la conversione in background
monitor_and_convert() {
    log_message "Avvio del monitoraggio e conversione automatica delle serie DICOM..."
   
    # Assicurati che la directory di log esista
    mkdir -p "$(dirname "$LOG_FILE")"
   
    # Ciclo infinito per monitorare e convertire continuamente
    while true; do
        main # Esegue la funzione principale di conversione
        log_message "Attendo 30 secondi prima di cercare nuove serie da convertire..."
        sleep 30 # Attende 30 secondi prima di ripetere il ciclo
    done
}


# Avvia il processo di monitoraggio e conversione quando lo script viene eseguito
monitor_and_convert
