#!/bin/bash

# Directory dove si trovano gli output di PyRadiomics (CSV)
INPUT_PR_DIR="/output_pradiomics"
# Directory dove salvare i PDF
OUTPUT_PDF_DIR="/output_pdf"
# Directory base dove si trovano i NIfTI originali (immagini)
NIFTI_BASE_DIR="/nifti"
# Directory base dove si trovano le maschere NIfTI di TotalSegmentator
TS_BASE_DIR="/output_ts"

# Log file
LOG_FILE="/var/log/csv_to_pdf_processing.log"

# Funzione per logging
log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] CSV2PDF: $1" | tee -a "$LOG_FILE"
}

# Funzione per convertire CSV in PDF usando Python
# Riceve come argomenti: percorso_csv, percorso_pdf_output, percorso_nifti_originale, percorso_maschera_nifti
convert_csv_to_pdf() {
    local csv_file="$1"
    local pdf_output="$2"
    local original_nifti_path="$3"
    local segmentation_nifti_path="$4"
    
    python3 -c "
import pandas as pd
import matplotlib.pyplot as plt
from matplotlib.backends.backend_pdf import PdfPages
import sys
import os
import nibabel as nib
import numpy as np

def find_best_slice_for_segmentation(mask_data, axis=1):
    \"\"\"
    Trova la fetta migliore per visualizzare la segmentazione.
    
    Args:
        mask_data: Array numpy della maschera
        axis: Asse lungo cui cercare (1 = coronale, 0 = sagittale, 2 = assiale)
    
    Returns:
        int: Indice della fetta migliore
    \"\"\"
    # Calcola la somma dei voxel della maschera per ogni fetta
    slice_sums = np.sum(mask_data, axis=tuple(i for i in range(3) if i != axis))
    
    # Trova la fetta con il maggior numero di voxel segmentati
    if np.sum(slice_sums) == 0:  # Nessuna segmentazione trovata
        return mask_data.shape[axis] // 2  # Ritorna la fetta centrale
    
    best_slice = np.argmax(slice_sums)
    return best_slice

def get_slice_and_orientation(mask_data):
    \"\"\"
    Determina il miglior piano di visualizzazione e l'orientamento.
    
    Returns:
        tuple: (axis, slice_index, rotation_angle, flip_horizontal, flip_vertical)
    \"\"\"
    axes_names = ['sagittale', 'coronale', 'assiale']
    best_axis = 1  # Default coronale
    best_slice = mask_data.shape[1] // 2
    max_coverage = 0
    
    # Testa tutti e tre i piani anatomici
    for axis in [0, 1, 2]:  # sagittale, coronale, assiale
        slice_sums = np.sum(mask_data, axis=tuple(i for i in range(3) if i != axis))
        if np.sum(slice_sums) > 0:
            coverage = np.max(slice_sums)
            if coverage > max_coverage:
                max_coverage = coverage
                best_axis = axis
                best_slice = np.argmax(slice_sums)
    
    # Determina rotazione e flip in base al piano
    rotation_angle = 0
    flip_horizontal = False
    flip_vertical = False
    
    if best_axis == 0:  # Sagittale
        rotation_angle = 0
        flip_vertical = True
    elif best_axis == 1:  # Coronale  
        rotation_angle = 0
        flip_vertical = True
    else:  # Assiale
        rotation_angle = 0
    
    return best_axis, best_slice, rotation_angle, flip_horizontal, flip_vertical

def apply_transforms(image_slice, rotation_angle, flip_horizontal, flip_vertical):
    \"\"\"Applica trasformazioni all'immagine.\"\"\"
    img = image_slice.copy()
    
    if flip_horizontal:
        img = np.fliplr(img)
    if flip_vertical:
        img = np.flipud(img)
    if rotation_angle != 0:
        img = np.rot90(img, k=rotation_angle//90)
    
    return img

def create_pdf_report(csv_path, pdf_path, original_nifti, segmentation_nifti):
    try:
        # Leggi il CSV
        df = pd.read_csv(csv_path)
        
        with PdfPages(pdf_path) as pdf:
            # Pagina 1: Informazioni generali
            fig, ax = plt.subplots(figsize=(11.69, 8.27))  # A4 landscape
            ax.axis('off')
            
            # Titolo
            fig.suptitle('PyRadiomics Feature Extraction Report', fontsize=16, fontweight='bold')
            
            # Informazioni base
            if not df.empty:
                info_text = []
                info_text.append(f'Image: {os.path.basename(df.iloc[0][\"Image\"]) if \"Image\" in df.columns else \"N/A\"}')
                info_text.append(f'Mask: {os.path.basename(df.iloc[0][\"Mask\"]) if \"Mask\" in df.columns else \"N/A\"}')
                info_text.append(f'PyRadiomics Version: {df.iloc[0][\"diagnostics_Versions_PyRadiomics\"] if \"diagnostics_Versions_PyRadiomics\" in df.columns else \"N/A\"}')
                info_text.append(f'Processing Date: {pd.Timestamp.now().strftime(\"%Y-%m-%d %H:%M:%S\")}')
                info_text.append(f'Total Features: {len([col for col in df.columns if col.startswith(\"original_\")])}')
                
                ax.text(0.05, 0.9, '\\n'.join(info_text), transform=ax.transAxes, 
                                fontsize=12, verticalalignment='top', fontfamily='monospace')
            
            pdf.savefig(fig, bbox_inches='tight')
            plt.close()
            
            # --- Pagina Immagine Overlay Intelligente ---
            if os.path.exists(original_nifti) and os.path.exists(segmentation_nifti):
                try:
                    img_nii = nib.load(original_nifti)
                    mask_nii = nib.load(segmentation_nifti)
                    
                    img_data = img_nii.get_fdata()
                    mask_data = mask_nii.get_fdata()
                    
                    # Assicurati che le dimensioni siano compatibili
                    if img_data.shape != mask_data.shape:
                        print(f'Warning: Image and mask shapes do not match for {os.path.basename(original_nifti)} and {os.path.basename(segmentation_nifti)}', file=sys.stderr)
                        # Ridimensiona alla dimensione minima
                        min_shape = tuple(min(img_data.shape[i], mask_data.shape[i]) for i in range(3))
                        img_data = img_data[:min_shape[0], :min_shape[1], :min_shape[2]]
                        mask_data = mask_data[:min_shape[0], :min_shape[1], :min_shape[2]]

                    # Trova il miglior piano e fetta per la visualizzazione
                    best_axis, best_slice, rotation_angle, flip_h, flip_v = get_slice_and_orientation(mask_data)
                    
                    axes_names = ['Sagittale', 'Coronale', 'Assiale']
                    axis_coords = ['X', 'Y', 'Z']
                    
                    # Estrai le fette appropriate
                    if best_axis == 0:  # Sagittale
                        img_slice = img_data[best_slice, :, :]
                        mask_slice = mask_data[best_slice, :, :]
                    elif best_axis == 1:  # Coronale
                        img_slice = img_data[:, best_slice, :]
                        mask_slice = mask_data[:, best_slice, :]
                    else:  # Assiale
                        img_slice = img_data[:, :, best_slice]
                        mask_slice = mask_data[:, :, best_slice]
                    
                    # Applica trasformazioni per orientamento ottimale
                    img_slice = apply_transforms(img_slice, rotation_angle, flip_h, flip_v)
                    mask_slice = apply_transforms(mask_slice, rotation_angle, flip_h, flip_v)
                    
                    # Crea la figura
                    fig, ax = plt.subplots(figsize=(11.69, 8.27))  # A4 landscape
                    
                    # Migliora il contrasto dell'immagine
                    img_display = img_slice.copy()
                    p2, p98 = np.percentile(img_display[img_display > 0], [2, 98])
                    img_display = np.clip((img_display - p2) / (p98 - p2), 0, 1)
                    
                    # Visualizza l'immagine di base
                    ax.imshow(img_display, cmap='gray', aspect='equal')
                    
                    # Overlay della maschera con rosso acceso e trasparenza
                    mask_colored = np.zeros((*mask_slice.shape, 4))  # RGBA
                    mask_binary = mask_slice > 0
                    mask_colored[mask_binary] = [1, 0, 0, 0.6]  # Rosso acceso con alpha 0.6
                    
                    ax.imshow(mask_colored, aspect='equal')
                    
                    # Calcola statistiche sulla segmentazione
                    total_voxels = np.sum(mask_slice > 0)
                    mask_name = os.path.basename(segmentation_nifti).replace('.nii', '')
                    
                    title = f'Segmentation Overlay - {mask_name}\\n'
                    title += f'{axes_names[best_axis]} View (Slice {best_slice}/{img_data.shape[best_axis]-1}) - '
                    title += f'Segmented voxels in slice: {total_voxels}'
                    
                    ax.set_title(title, fontsize=12, fontweight='bold', pad=20)
                    ax.axis('off')
                    
                    # Aggiungi una scala di colore per la maschera
                    from matplotlib.patches import Rectangle
                    legend_x, legend_y = 0.02, 0.02
                    rect = Rectangle((legend_x, legend_y), 0.15, 0.05, 
                                   transform=ax.transAxes, facecolor='red', alpha=0.6)
                    ax.add_patch(rect)
                    ax.text(legend_x + 0.17, legend_y + 0.025, 'Segmentation', 
                           transform=ax.transAxes, fontsize=10, va='center')
                    
                    plt.tight_layout()
                    pdf.savefig(fig, bbox_inches='tight', dpi=150)
                    plt.close()

                except Exception as e:
                    print(f'Errore nel caricamento o plotting NIfTI: {str(e)}', file=sys.stderr)
                    # Crea una pagina di errore
                    fig, ax = plt.subplots(figsize=(11.69, 8.27))
                    ax.axis('off')
                    ax.text(0.5, 0.5, f'Errore nel caricamento delle immagini NIfTI:\\n{str(e)}', 
                           transform=ax.transAxes, ha='center', va='center', fontsize=12)
                    pdf.savefig(fig, bbox_inches='tight')
                    plt.close()
            else:
                # Crea una pagina che indica file mancanti
                fig, ax = plt.subplots(figsize=(11.69, 8.27))
                ax.axis('off')
                missing_files = []
                if not os.path.exists(original_nifti):
                    missing_files.append(f'Immagine originale: {original_nifti}')
                if not os.path.exists(segmentation_nifti):
                    missing_files.append(f'Maschera di segmentazione: {segmentation_nifti}')
                
                ax.text(0.5, 0.5, f'File NIfTI mancanti per la visualizzazione:\\n\\n' + '\\n'.join(missing_files), 
                       transform=ax.transAxes, ha='center', va='center', fontsize=12)
                pdf.savefig(fig, bbox_inches='tight')
                plt.close()

            # Pagina 2: Features Shape
            shape_cols = [col for col in df.columns if col.startswith('original_shape_')]
            if shape_cols:
                fig, ax = plt.subplots(figsize=(11.69, 8.27))
                ax.axis('off')
                fig.suptitle('Shape Features', fontsize=14, fontweight='bold')
                
                shape_data = []
                for col in shape_cols:
                    feature_name = col.replace('original_shape_', '')
                    value = df.iloc[0][col] if not df.empty else 'N/A'
                    shape_data.append([feature_name, f'{value:.6f}' if isinstance(value, (int, float)) else str(value)])
                
                # Crea tabella
                table = ax.table(cellText=shape_data, 
                                colLabels=['Feature', 'Value'],
                                cellLoc='left',
                                loc='center',
                                colWidths=[0.5, 0.3])
                table.auto_set_font_size(False)
                table.set_fontsize(9)
                table.scale(1, 1.5)
                
                pdf.savefig(fig, bbox_inches='tight')
                plt.close()
            
            # Pagina 3: Features First Order
            firstorder_cols = [col for col in df.columns if col.startswith('original_firstorder_')]
            if firstorder_cols:
                fig, ax = plt.subplots(figsize=(11.69, 8.27))
                ax.axis('off')
                fig.suptitle('First Order Features', fontsize=14, fontweight='bold')
                
                firstorder_data = []
                for col in firstorder_cols:
                    feature_name = col.replace('original_firstorder_', '')
                    value = df.iloc[0][col] if not df.empty else 'N/A'
                    firstorder_data.append([feature_name, f'{value:.6f}' if isinstance(value, (int, float)) else str(value)])
                
                table = ax.table(cellText=firstorder_data,
                                colLabels=['Feature', 'Value'],
                                cellLoc='left',
                                loc='center',
                                colWidths=[0.5, 0.3])
                table.auto_set_font_size(False)
                table.set_fontsize(9)
                table.scale(1, 1.5)
                
                pdf.savefig(fig, bbox_inches='tight')
                plt.close()
            
            # Pagina 4: Features GLCM
            glcm_cols = [col for col in df.columns if col.startswith('original_glcm_')]
            if glcm_cols:
                fig, ax = plt.subplots(figsize=(11.69, 8.27))
                ax.axis('off')
                fig.suptitle('GLCM Features', fontsize=14, fontweight='bold')
                
                glcm_data = []
                for col in glcm_cols:
                    feature_name = col.replace('original_glcm_', '')
                    value = df.iloc[0][col] if not df.empty else 'N/A'
                    glcm_data.append([feature_name, f'{value:.6f}' if isinstance(value, (int, float)) else str(value)])
                
                table = ax.table(cellText=glcm_data,
                                colLabels=['Feature', 'Value'],
                                cellLoc='left',
                                loc='center',
                                colWidths=[0.5, 0.3])
                table.auto_set_font_size(False)
                table.set_fontsize(9)
                table.scale(1, 1.5)
                
                pdf.savefig(fig, bbox_inches='tight')
                plt.close()
            
            # Pagina 5: Features GLDM
            gldm_cols = [col for col in df.columns if col.startswith('original_gldm_')]
            if gldm_cols:
                fig, ax = plt.subplots(figsize=(11.69, 8.27))
                ax.axis('off')
                fig.suptitle('GLDM Features', fontsize=14, fontweight='bold')
                
                gldm_data = []
                for col in gldm_cols:
                    feature_name = col.replace('original_gldm_', '')
                    value = df.iloc[0][col] if not df.empty else 'N/A'
                    gldm_data.append([feature_name, f'{value:.6f}' if isinstance(value, (int, float)) else str(value)])
                
                table = ax.table(cellText=gldm_data,
                                colLabels=['Feature', 'Value'],
                                cellLoc='left',
                                loc='center',
                                colWidths=[0.5, 0.3])
                table.auto_set_font_size(False)
                table.set_fontsize(9)
                table.scale(1, 1.5)
                
                pdf.savefig(fig, bbox_inches='tight')
                plt.close()
            
            # Pagina 6: Features GLRLM
            glrlm_cols = [col for col in df.columns if col.startswith('original_glrlm_')]
            if glrlm_cols:
                fig, ax = plt.subplots(figsize=(11.69, 8.27))
                ax.axis('off')
                fig.suptitle('GLRLM Features', fontsize=14, fontweight='bold')
                
                glrlm_data = []
                for col in glrlm_cols:
                    feature_name = col.replace('original_glrlm_', '')
                    value = df.iloc[0][col] if not df.empty else 'N/A'
                    glrlm_data.append([feature_name, f'{value:.6f}' if isinstance(value, (int, float)) else str(value)])
                
                table = ax.table(cellText=glrlm_data,
                                colLabels=['Feature', 'Value'],
                                cellLoc='left',
                                loc='center',
                                colWidths=[0.5, 0.3])
                table.auto_set_font_size(False)
                table.set_fontsize(9)
                table.scale(1, 1.5)
                
                pdf.savefig(fig, bbox_inches='tight')
                plt.close()
            
            # Pagina 7: Features GLSZM
            glszm_cols = [col for col in df.columns if col.startswith('original_glszm_')]
            if glszm_cols:
                fig, ax = plt.subplots(figsize=(11.69, 8.27))
                ax.axis('off')
                fig.suptitle('GLSZM Features', fontsize=14, fontweight='bold')
                
                glszm_data = []
                for col in glszm_cols:
                    feature_name = col.replace('original_glszm_', '')
                    value = df.iloc[0][col] if not df.empty else 'N/A'
                    glszm_data.append([feature_name, f'{value:.6f}' if isinstance(value, (int, float)) else str(value)])
                
                table = ax.table(cellText=glszm_data,
                                colLabels=['Feature', 'Value'],
                                cellLoc='left',
                                loc='center',
                                colWidths=[0.5, 0.3])
                table.auto_set_font_size(False)
                table.set_fontsize(9)
                table.scale(1, 1.5)
                
                pdf.savefig(fig, bbox_inches='tight')
                plt.close()
            
            # Pagina 8: Features NGTDM
            ngtdm_cols = [col for col in df.columns if col.startswith('original_ngtdm_')]
            if ngtdm_cols:
                fig, ax = plt.subplots(figsize=(11.69, 8.27))
                ax.axis('off')
                fig.suptitle('NGTDM Features', fontsize=14, fontweight='bold')
                
                ngtdm_data = []
                for col in ngtdm_cols:
                    feature_name = col.replace('original_ngtdm_', '')
                    value = df.iloc[0][col] if not df.empty else 'N/A'
                    ngtdm_data.append([feature_name, f'{value:.6f}' if isinstance(value, (int, float)) else str(value)])
                
                table = ax.table(cellText=ngtdm_data,
                                colLabels=['Feature', 'Value'],
                                cellLoc='left',
                                loc='center',
                                colWidths=[0.5, 0.3])
                table.auto_set_font_size(False)
                table.set_fontsize(9)
                table.scale(1, 1.5)
                
                pdf.savefig(fig, bbox_inches='tight')
                plt.close()
                
        return True
        
    except Exception as e:
        print(f'Errore durante la creazione del PDF: {str(e)}', file=sys.stderr)
        return False

# Esegui la conversione
if __name__ == '__main__':
    if len(sys.argv) != 5:
        print('Utilizzo: python script.py <csv_file> <pdf_output> <original_nifti_path> <segmentation_nifti_path>', file=sys.stderr)
        sys.exit(1)
    
    csv_file = sys.argv[1]
    pdf_output = sys.argv[2]
    original_nifti_path = sys.argv[3]
    segmentation_nifti_path = sys.argv[4]
    
    success = create_pdf_report(csv_file, pdf_output, original_nifti_path, segmentation_nifti_path)
    sys.exit(0 if success else 1)
" "$csv_file" "$pdf_output" "$original_nifti_path" "$segmentation_nifti_path"
}

# Funzione per processare un CSV con conversione PDF
process_csv_to_pdf() {
    local pr_series_dir="$1"
    local processed_pdf_file="${pr_series_dir}/.processed_pdf" # File di marcatura per PDF
    
    # Estrai il percorso relativo rispetto a INPUT_PR_DIR
    local rel_path="${pr_series_dir#$INPUT_PR_DIR/}"
    local output_pdf_series_dir="${OUTPUT_PDF_DIR}/${rel_path}"

    # Verifica se la serie è già stata processata per PDF
    if [ -f "$processed_pdf_file" ]; then
        log_message "Serie già processata per PDF, saltando: $pr_series_dir"
        return
    fi

    # Crea la directory di destinazione per PDF se non esiste
    mkdir -p "$output_pdf_series_dir"

    log_message "Ricerca file CSV in: $pr_series_dir per conversione PDF..."

    find "$pr_series_dir" -maxdepth 1 -type f -name "features_*.csv" | while IFS= read -r csv_path; do
        
        # Estrai il nome del file CSV (es. features_trachea.csv)
        local csv_filename=$(basename "$csv_path")
        # Il nome della maschera NIfTI corrispondente (es. trachea.nii)
        local mask_filename="${csv_filename#features_}" # rimuove "features_"
        mask_filename="${mask_filename%.csv}.nii"       # cambia .csv in .nii

        # Costruisci i percorsi completi per l'immagine originale e la maschera
        # La struttura della directory dovrebbe essere /nifti/STUDY_ID/SERIES_ID/series.nii
        # E la maschera in /output_ts/STUDY_ID/SERIES_ID/mask_name.nii
        local original_nifti_path="${NIFTI_BASE_DIR}/${rel_path}/series.nii"
        local segmentation_nifti_path="${TS_BASE_DIR}/${rel_path}/${mask_filename}"

        # Verifica che i file NIfTI esistano prima di procedere
        if [ ! -f "$original_nifti_path" ]; then
            log_message "WARNING: Immagine NIfTI originale non trovata: $original_nifti_path. Non sarà possibile generare l'overlap nel PDF per $csv_path."
            original_nifti_path="N/A" # Passa N/A al python script per gestire l'assenza
        fi
        if [ ! -f "$segmentation_nifti_path" ]; then
            log_message "WARNING: Maschera NIfTI non trovata: $segmentation_nifti_path. Non sarà possibile generare l'overlap nel PDF per $csv_path."
            segmentation_nifti_path="N/A" # Passa N/A al python script per gestire l'assenza
        fi

        local output_pdf_file="${output_pdf_series_dir}/${csv_filename%.csv}.pdf"

        log_message "Avvio conversione CSV to PDF per: $csv_path"
        log_message "Salvando PDF in: $output_pdf_file"
        log_message "Utilizzando immagine: $original_nifti_path e maschera: $segmentation_nifti_path per l'overlap."

        # Chiamata al comando Python con i nuovi argomenti
        convert_csv_to_pdf "$csv_path" "$output_pdf_file" "$original_nifti_path" "$segmentation_nifti_path"

        if [ $? -eq 0 ]; then
            log_message "Conversione CSV to PDF completata con successo per: $csv_path"
        else
            log_message "Errore durante la conversione CSV to PDF per: $csv_path"
        fi
    done

    # Marca la serie come processata solo dopo aver tentato tutte le conversioni
    echo "Processato CSV to PDF: $(date)" > "$processed_pdf_file"
}

# Funzione principale per monitorare e processare
monitor_and_process_pr_output() {
    log_message "Avvio monitoraggio e conversione output PyRadiomics (CSV) in PDF..."
    
    # Assicurati che le directory esistano
    mkdir -p "$OUTPUT_PDF_DIR"
    mkdir -p "$(dirname "$LOG_FILE")"

    # Verifica che Python3 e le librerie necessarie siano installate
    if ! command -v python3 &> /dev/null; then
        log_message "ERRORE: Python3 non trovato. Installare Python3 per continuare."
        exit 1
    fi

    # Verifica librerie Python necessarie, inclusa nibabel
    python3 -c "import pandas, matplotlib, nibabel, sys; sys.exit(0)" 2>/dev/null
    if [ $? -ne 0 ]; then
        log_message "ERRORE: Librerie Python mancanti. Installare: pip3 install pandas matplotlib nibabel"
        exit 1
    fi

    while true; do
        # Trova tutte le directory di serie PyRadiomics che hanno un file .processed_pr (da PyRadiomics)
        # e non hanno ancora un file .processed_pdf (da questo script)
        while IFS= read -r processed_pr_file; do
            pr_series_dir=$(dirname "$processed_pr_file")
            processed_pdf_file="${pr_series_dir}/.processed_pdf"
            
            # Verifica che la directory contenga almeno un file CSV features_*.csv
            if find "$pr_series_dir" -maxdepth 1 -type f -name "features_*.csv" -print -quit | grep -q .; then
                if [ ! -f "$processed_pdf_file" ]; then
                    process_csv_to_pdf "$pr_series_dir"
                fi
            fi
        done < <(find "$INPUT_PR_DIR" -name ".processed_pr" -type f)
        
        log_message "Attendo 30 secondi prima di cercare nuovi CSV da convertire in PDF..."
        sleep 30
    done
}

# Avvia il processo di monitoraggio e conversione
monitor_and_process_pr_output