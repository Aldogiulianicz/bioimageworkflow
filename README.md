# Pipeline bioimageworkflow

## Descrizione del progetto
Questa pipeline, sviluppata come progetto di tesi, consente l’analisi automatizzata di immagini TC combinando:
- gestione DICOM,
- conversione in NIfTI,
- segmentazione multi-organo automatica,
- estrazione di caratteristiche radiomiche.

L’intero workflow è containerizzato con Docker, garantendo riproducibilità e portabilità.

---

## Strumenti principali
- **Orthanc** → Server DICOM per gestione e archiviazione
- **Plastimatch** → Conversione DICOM → NIfTI
- **TotalSegmentator** → Segmentazione automatica (117 strutture)
- **PyRadiomics** → Estrazione di features quantitative

---

## Workflow della pipeline
1. **Download dei dati** → i file DICOM vengono gestiti e recuperati da Orthanc.  
2. **Conversione** → Plastimatch converte i DICOM in NIfTI:  
   ```bash
   plastimatch convert --input /path/to/dicom/folder --output-img /path/to/output/image.nii.gz
   ```
3. **Segmentazione** → TotalSegmentator segmenta il volume NIfTI:  
   ```bash
   TotalSegmentator -i image.nii.gz -o output_ts/
   ```
   Opzioni:
   - `--fast`: modalità più veloce, minore accuratezza  
   - `-ta total`: modalità più accurata, maggior uso di risorse  
4. **Feature extraction** → PyRadiomics calcola le features e salva in CSV.  
5. **Output finale** → generazione report PDF con segmentazioni e features radiomiche.

---

## Struttura delle directory
Nota: Tutto il workflow deve essere inserito in una cartella principale chiamata `progetto_tesi_github/`.  
Le sottocartelle devono essere create sia sulla workstation che all’interno del container.

```plaintext
progetto_tesi_github/
├── download/          # File DICOM originali
├── nifti/             # Volumi NIfTI convertiti
├── output_ts/         # Maschere segmentate da TotalSegmentator
├── output_pradiomics/ # File CSV con features radiomiche
└── output_pdf/        # Report finale della pipeline
```

---

## Esecuzione con Docker
### Build dell’immagine
```bash
docker build -t workflow:latest .
```

### Run del container
```bash
docker run --gpus "device=0" --shm-size=8g -it --rm   -v /path/to/progetto_tesi_github/download:/download   -v /path/to/progetto_tesi_github/nifti:/nifti   -v /path/to/progetto_tesi_github/output_ts:/output_ts   -v /path/to/progetto_tesi_github/output_pradiomics:/output_pradiomics   -v /path/to/progetto_tesi_github/output_pdf:/output_pdf   workflow:latest
```

---

## Riferimenti
- Jodogne, S. (2018). *The Orthanc Ecosystem for Medical Imaging*. J. Digital Imaging  
- Sharp, G. C., et al. (2010). *Plastimatch - An open source software suite for radiotherapy image processing*. IEEE ISBI  
- Wasserthal, J., et al. (2023). *TotalSegmentator: robust segmentation of 104 anatomical structures in CT images*. Sci. Reports  
- van Griethuysen, J. J. M., et al. (2017). *Computational radiomics system to decode the radiographic phenotype*. Cancer Research  
