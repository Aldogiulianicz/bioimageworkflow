#!/bin/bash

ORTHANC_URL="http://localhost:8052"
DOWNLOAD_DIR="/download"

sanitize() {
    # Rimuove spazi, slash e caratteri non validi per i nomi di file/cartelle
    echo "$1" | tr ' ' '_' | tr -cd '[:alnum:]_-'
}

# Assicurati che jq sia installato
if ! command -v jq &> /dev/null; then
    echo "Errore: jq non trovato."
    exit 1
fi

# Funzione per scaricare un'istanza DICOM
download_instance() {
    local instance_id="$1"
    local patient_name="$2"
    local study_desc="$3"
    local series_desc="$4"
    
    local patient_dir="${DOWNLOAD_DIR}/$(sanitize "$patient_name")"
    local study_dir="${patient_dir}/$(sanitize "$study_desc")"
    local series_dir="${study_dir}/$(sanitize "$series_desc")"
    mkdir -p "$series_dir"
    
    local output_file="${series_dir}/${instance_id}.dcm"
    local instance_url="${ORTHANC_URL}/instances/${instance_id}/file"
    
    if [ -f "$output_file" ]; then
        echo "Il file ${output_file} esiste già, skip."
        return
    fi
    
    echo "Scaricando: ${output_file}"
    curl -s -o "$output_file" "$instance_url"
    if [ $? -ne 0 ]; then
        echo "Errore durante il download di ${instance_id}"
    fi
}

# Funzione per creare il file .done per una serie completata
mark_series_done() {
    local patient_name="$1"
    local study_desc="$2"
    local series_desc="$3"
    local series_id="$4"
    local instances_count="$5"
    
    local patient_dir="${DOWNLOAD_DIR}/$(sanitize "$patient_name")"
    local study_dir="${patient_dir}/$(sanitize "$study_desc")"
    local series_dir="${study_dir}/$(sanitize "$series_desc")"
    local done_file="${series_dir}/.done"
    
    # Controlla se il file .done esiste già
    if [ -f "$done_file" ]; then
        return
    fi
    
    # Crea il file .done con alcune informazioni utili
    echo "Serie completata: $(date)" > "$done_file"
    echo "ID serie: $series_id" >> "$done_file"
    echo "Numero di istanze: $instances_count" >> "$done_file"
    echo "Download completato il: $(date)" >> "$done_file"
    
    echo "Serie marcata come completata: $series_dir"
}

# Funzione per verificare se ci sono modifiche di istanze
check_changes() {
    local prev_count="$1"
    local current_count="$2"
    local stable_count="$3"
    
    echo "Istanze precedenti: $prev_count, Istanze attuali: $current_count, Cicli stabili: $stable_count"
    
    if [ "$prev_count" -eq "$current_count" ]; then
        echo "Nessuna nuova istanza rilevata. Ciclo stabile: $((stable_count+1))"
        return $((stable_count+1))
    else
        echo "Rilevate nuove istanze ($((current_count-prev_count))). Reset contatore stabilità."
        return 0
    fi
}

# Funzione per contare tutte le istanze in Orthanc
count_all_instances() {
    local total_instances=0
    
    # Ottieni la lista dei pazienti
    local patients_json=$(curl -s "${ORTHANC_URL}/patients")
    local patients=$(echo "$patients_json" | jq -r '.[]')
    
    for patient_id in $patients; do
        # Ottieni studi per paziente
        local patient_info=$(curl -s "${ORTHANC_URL}/patients/${patient_id}")
        local studies=$(echo "$patient_info" | jq -r '.Studies[]')
        
        for study_id in $studies; do
            # Ottieni serie per studio
            local study_info=$(curl -s "${ORTHANC_URL}/studies/${study_id}")
            local series_list=$(echo "$study_info" | jq -r '.Series[]')
            
            for series_id in $series_list; do
                # Conta istanze per serie
                local series_info=$(curl -s "${ORTHANC_URL}/series/${series_id}")
                local instances=$(echo "$series_info" | jq -r '.Instances[]')
                local instance_count=$(echo "$instances" | wc -w)
                total_instances=$((total_instances + instance_count))
            done
        done
    done
    
    echo $total_instances
}

# Funzione principale che rimane in ascolto
main_loop() {
    while true; do
        echo "In attesa che Orthanc sia pronto..."
        while ! curl -s "${ORTHANC_URL}/system" > /dev/null; do
            echo "Orthanc non è ancora pronto, attendere..."
            sleep 2
        done
        
        echo "Verifico la stabilità delle istanze in Orthanc..."
        local prev_instance_count=0
        local current_instance_count=0
        local stable_cycles=0
        local required_stable_cycles=5  # Numero di cicli di stabilità richiesti
        
        # Loop per verificare la stabilità delle istanze
        while [ $stable_cycles -lt $required_stable_cycles ]; do
            prev_instance_count=$current_instance_count
            current_instance_count=$(count_all_instances)
            
            check_changes "$prev_instance_count" "$current_instance_count" "$stable_cycles"
            stable_cycles=$?
            
            echo "Attendo 5 secondi prima di ricontrollare la stabilità..."
            sleep 5
        done
        
        echo "Orthanc è stabile con $current_instance_count istanze. Inizio download..."
        
        # Ottieni la lista dei pazienti
        patients_json=$(curl -s "${ORTHANC_URL}/patients")
        patients=$(echo "$patients_json" | jq -r '.[]')
        
        if [ -z "$patients" ]; then
            echo "Nessun paziente trovato in Orthanc."
            sleep 10
            continue
        fi
        
        for patient_id in $patients; do
            echo "Elaborazione del paziente: $patient_id"
            patient_info=$(curl -s "${ORTHANC_URL}/patients/${patient_id}")
            patient_name=$(echo "$patient_info" | jq -r '.MainDicomTags.PatientName // "UnknownPatient"')
            studies=$(echo "$patient_info" | jq -r '.Studies[]')
            
            for study_id in $studies; do
                study_info=$(curl -s "${ORTHANC_URL}/studies/${study_id}")
                study_desc=$(echo "$study_info" | jq -r '.MainDicomTags.StudyDescription // "UnknownStudy"')
                series_list=$(echo "$study_info" | jq -r '.Series[]')
                
                for series_id in $series_list; do
                    series_info=$(curl -s "${ORTHANC_URL}/series/${series_id}")
                    series_desc=$(echo "$series_info" | jq -r '.MainDicomTags.SeriesDescription // "UnknownSeries"')
                    instances=$(echo "$series_info" | jq -r '.Instances[]')
                    
                    # Conta il numero di istanze per questa serie
                    instances_count=$(echo "$instances" | wc -w)
                    
                    # Verifica se esiste già il file .done per questa serie
                    local patient_dir="${DOWNLOAD_DIR}/$(sanitize "$patient_name")"
                    local study_dir="${patient_dir}/$(sanitize "$study_desc")"
                    local series_dir="${study_dir}/$(sanitize "$series_desc")"
                    local done_file="${series_dir}/.done"
                    
                    if [ -f "$done_file" ]; then
                        echo "Serie già scaricata completamente: $series_dir"
                        continue
                    fi
                    
                    # Scarica tutte le istanze per questa serie
                    downloaded_instances=0
                    for instance_id in $instances; do
                        download_instance "$instance_id" "$patient_name" "$study_desc" "$series_desc"
                        downloaded_instances=$((downloaded_instances+1))
                        sleep 0.1
                    done
                    
                    # Verifica che tutte le istanze siano state scaricate
                    if [ $downloaded_instances -eq $instances_count ]; then
                        mark_series_done "$patient_name" "$study_desc" "$series_desc" "$series_id" "$instances_count"
                    else
                        echo "Attenzione: Non tutte le istanze sono state scaricate per la serie $series_id ($downloaded_instances/$instances_count)"
                    fi
                done
            done
        done
        
        echo "Download completato. Aspetto 30 secondi prima di ripetere..."
        sleep 30
    done
}

main_loop