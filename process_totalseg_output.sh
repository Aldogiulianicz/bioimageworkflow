#!/bin/bash

# Directory dove si trovano gli output di TotalSegmentator
INPUT_TS_DIR="/output_ts"
# Directory dove salvare gli output di PyRadiomics
OUTPUT_PR_DIR="/output_pradiomics"

# Log file
LOG_FILE="/var/log/pyradiomics_processing.log"

# Funzione per logging
log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] PyRadiomics: $1" | tee -a "$LOG_FILE"
}

# Funzione per verificare se una maschera NIfTI contiene segmentazioni
check_mask_not_empty() {
    local mask_path="$1"
    
    # Usa fslstats per controllare se ci sono voxel con valore > 0
    # Se non hai fsl, puoi usare altri tool come nibabel in Python
    local max_value=$(fslstats "$mask_path" -R | cut -d' ' -f2)
    
    # Se il valore massimo è 0, la maschera è vuota
    if (( $(echo "$max_value > 0" | bc -l) )); then
        return 0  # Maschera non vuota
    else
        return 1  # Maschera vuota
    fi
}

# Versione alternativa senza FSL (usando Python)
check_mask_not_empty_python() {
    local mask_path="$1"
    
    python3 -c "
import nibabel as nib
import numpy as np
import sys

try:
    img = nib.load('$mask_path')
    data = img.get_fdata()
    if np.any(data > 0):
        sys.exit(0)  # Maschera non vuota
    else:
        sys.exit(1)  # Maschera vuota
except Exception as e:
    print(f'Errore nel controllo maschera: {e}')
    sys.exit(1)
"
}

# Funzione per processare un output di TotalSegmentator con PyRadiomics
process_with_pyradiomics() {
    local ts_series_dir="$1"
    local original_nifti_path=""
    
    # Estrai il percorso relativo rispetto a INPUT_TS_DIR
    local rel_path="${ts_series_dir#$INPUT_TS_DIR/}"
    local output_pr_series_dir="${OUTPUT_PR_DIR}/${rel_path}"

    # DEFINIAMO IL PERCORSO CORRETTO PER IL FLAG .processed_pr
    local processed_pr_file="${output_pr_series_dir}/.processed_pr" 

    # Verifica se la serie è già stata processata da PyRadiomics
    if [ -f "$processed_pr_file" ]; then
        log_message "Serie già processata da PyRadiomics, saltando: $ts_series_dir"
        return
    fi

    original_nifti_path="/nifti/${rel_path}/series.nii"
    
    if [ ! -f "$original_nifti_path" ]; then
        log_message "File NIfTI originale (immagine) non trovato: $original_nifti_path, saltando PyRadiomics per $ts_series_dir"
        return
    fi

    # Crea la directory di destinazione per PyRadiomics se non esiste
    mkdir -p "$output_pr_series_dir"

    log_message "Ricerca file di segmentazione in: $ts_series_dir per PyRadiomics..."

    find "$ts_series_dir" -maxdepth 1 -type f -name "*.nii" | while IFS= read -r segmentation_path; do
        
        local segmentation_filename=$(basename "$segmentation_path")
        local output_features_file="${output_pr_series_dir}/features_${segmentation_filename%.nii}.csv"

        # CONTROLLO MASCHERA VUOTA - SALTA SE VUOTA
        if ! check_mask_not_empty_python "$segmentation_path"; then
            log_message "Maschera vuota, saltando PyRadiomics per: $segmentation_path"
            continue
        fi

        log_message "Avvio estrazione features con PyRadiomics per immagine: $original_nifti_path e maschera: $segmentation_path"
        log_message "Salvando output in: $output_features_file"

        pyradiomics "$original_nifti_path" "$segmentation_path" --format csv --out "$output_features_file"

        if [ $? -eq 0 ]; then
            log_message "Estrazione features con PyRadiomics completata con successo per: $segmentation_path"
        else
            log_message "Errore durante l'estrazione features con PyRadiomics per: $segmentation_path"
        fi
    done

    # Marca la serie come processata solo dopo aver tentato tutte le segmentazioni
    echo "Processato con PyRadiomics: $(date)" > "$processed_pr_file"
}

# Funzione principale per monitorare e processare
monitor_and_process_ts_output() {
    log_message "Avvio monitoraggio e elaborazione output TotalSegmentator con PyRadiomics..."
    
    # Assicurati che la directory di output esista
    mkdir -p "$OUTPUT_PR_DIR"
    mkdir -p "$(dirname "$LOG_FILE")"

    while true; do
        # Trova tutte le directory di serie TotalSegmentator che hanno un file .processed_ts (da TotalSegmentator)
        # e non hanno ancora un file .processed_pr (da PyRadiomics)
        while IFS= read -r processed_ts_file; do
            ts_series_dir=$(dirname "$processed_ts_file")
            
            # Costruisci il percorso corretto per il flag .processed_pr nella directory di output di PyRadiomics
            local rel_path_for_pr="${ts_series_dir#$INPUT_TS_DIR/}" # Questo è ancora relativo a /output_ts
            local processed_pr_file_check="${OUTPUT_PR_DIR}/${rel_path_for_pr}/.processed_pr"

            # Verifica che la directory TotalSegmentator contenga almeno un file NIfTI
            if find "$ts_series_dir" -maxdepth 1 -type f -name "*.nii" -print -quit | grep -q .; then
                # Solo se il flag .processed_pr NON esiste ancora nella directory di output di PyRadiomics
                if [ ! -f "$processed_pr_file_check" ]; then
                    process_with_pyradiomics "$ts_series_dir"
                fi
            fi
        done < <(find "$INPUT_TS_DIR" -name ".processed_ts" -type f)
        
        log_message "Attendo 30 secondi prima di cercare nuovi output TotalSegmentator da processare con PyRadiomics..."
        sleep 30
    done
}

# Avvia il processo di monitoraggio e elaborazione
monitor_and_process_ts_output