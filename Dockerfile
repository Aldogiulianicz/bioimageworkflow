FROM nvidia/cuda:12.6.0-cudnn-devel-ubuntu24.04

# Imposta il frontend per evitare interruzioni durante l'installazione
ENV DEBIAN_FRONTEND=noninteractive

# Installa Orthanc, Plastimatch, jq, curl, Python e altre dipendenze comuni
RUN apt-get update && apt-get install -y --no-install-recommends \
    orthanc \
    plastimatch \
    python3 \
    python3-venv \
    python3-pip \
    python3-dev \
    build-essential \
    cmake \
    git \
    libgl1-mesa-dri \
    libgl1-mesa-dev \
    libglib2.0-0 \
    libsm6 \
    libxext6 \
    libxrender1 \
    libgomp1 \
    libgstreamer1.0-0 \
    libgstreamer-plugins-base1.0-0 \
    curl \
    unzip \
    jq \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Crea un link simbolico per python
RUN ln -s /usr/bin/python3 /usr/bin/python

# Crea un ambiente virtuale per Python
RUN python3 -m venv /venv

# Installa pip nell'ambiente virtuale
RUN /venv/bin/pip install --upgrade pip

# Aggiungi il percorso dell'ambiente virtuale alla variabile PATH
ENV PATH="/venv/bin:$PATH"

# Installa PyTorch per CUDA 12.6
RUN pip3 install torch torchvision torchaudio

# Installa TotalSegmentator
RUN pip install TotalSegmentator

# Scarica i pesi per TotalSegmentator
RUN totalseg_download_weights -t total && \
    totalseg_download_weights -t total_fast

# Installa le dipendenze Python necessarie per PyRadiomics
RUN pip install --break-system-packages numpy scipy scikit-image SimpleITK

# Installa PyRadiomics dal repository GitHub 
RUN pip install --break-system-packages git+https://github.com/AIM-Harvard/pyradiomics.git

RUN pip3 install pandas matplotlib nibabel

# Crea le cartelle di download e nifti nel container
RUN mkdir -p /download
RUN mkdir -p /nifti
RUN mkdir -p /output_ts
RUN mkdir -p /output_pradiomics
RUN mkdir -p /output_pdf

# Crea una directory di lavoro per l'applicazione (utile per PyRadiomics, anche se non strettamente necessaria per gli altri)
WORKDIR /app

# Copia i file di configurazione e script
COPY orthanc.json /etc/orthanc/
COPY download_orthanc_data.sh /
COPY convert_to_nifti.sh /
COPY process_nifti_data.sh /
COPY process_totalseg_output.sh /
COPY process_pdf.sh /

# Rendi eseguibili gli script
RUN chmod +x /download_orthanc_data.sh
RUN chmod +x /convert_to_nifti.sh
RUN chmod +x /process_nifti_data.sh
RUN chmod +x /process_totalseg_output.sh
RUN chmod +x /process_pdf.sh

# Crea la cartella per i dati di Orthanc (come volume)
VOLUME ["/var/lib/orthanc/db"]
VOLUME ["/download"]
VOLUME ["/nifti"]
VOLUME ["/output_ts"]
VOLUME ["/output_pradiomics"]
VOLUME ["/output_pdf"]

# Esponi le porte necessarie per Orthanc
EXPOSE 8052 4242

CMD ["sh", "-c", "Orthanc /etc/orthanc/orthanc.json & /download_orthanc_data.sh & /convert_to_nifti.sh & /process_nifti_data.sh & /process_totalseg_output.sh & exec /process_pdf.sh"]
