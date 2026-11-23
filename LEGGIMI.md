# Mécena Motion 0.10.0

Due effetti OpenFX per DaVinci Resolve su Mac. **Mecena Stabilize** stabilizza tramite Gyroflow integrato. **Mecena Shutter** ricostruisce il mosso dall’immagine che riceve. Puoi usare Shutter da solo oppure dopo la stabilizzazione.

## Installazione sul Mac

1. Estrai l’archivio sorgenti e apri la cartella **Motion0100**. Da Terminale puoi scrivere `bash `, trascinare **release/build-mac.sh** nella finestra e premere Invio. Servono Rust, gli strumenti da riga di comando di Xcode e Internet solo sulla macchina che compila. La build scarica le dipendenze bloccate e incorpora il catalogo degli obiettivi.
2. In **Motion0100/dist** apri **MecenaMotion-0.10.0-arm64.zip** su Apple Silicon. Al suo interno trovi **MecenaMotion.ofx.bundle**.
3. Chiudi Resolve e colloca il bundle in **/Library/OFX/Plugins/**, sostituendo la precedente copia di MecenaMotion. Riavvia Resolve. Per usare gli effetti sul Mac di montaggio basta il bundle.

## Il tuo caso da 50p a 25p

Sulla clip seleziona **Mecena Shutter → Look · FPS e shutter → Cinema · shutter sulla timeline** e lascia **Shutter desiderato (°)** a **180**. È la scelta predefinita sulle nuove istanze. Per aggiornare un effetto già in timeline selezionala esplicitamente. Il controllo in gradi accetta keyframe. In questo modo gli FPS e lo shutter inseriti nei vecchi preset di ripresa non intervengono nel calcolo.

A velocità reale, 50 fps e 90° corrispondono a una posa di 5 ms. Su una timeline a 25 fps ogni fotogramma dura 40 ms. Il look a 180° ricostruisce una posa di 20 ms, centrata sul fotogramma di timeline (da −10 a +10 ms). Con gli stessi 25 fps, 90° richiedono 10 ms e 360° ne richiedono 40. Lo shutter a zero riproduce il mosso già registrato.

Il filtro confronta il fotogramma centrale con il precedente e il successivo. Su una clip 50p in un flusso OFX 25p prova anche le due posizioni a mezzo frame. Usa questa coppia se entrambe le immagini contengono informazione distinta dagli estremi. Resolve può sintetizzarle. Se Resolve consegna soltanto 1, 3, 5, per l’uscita centrata sul 3 il filtro calcola lo spostamento verso 1 e 5, ricostruisce posizioni intermedie e integra la luce nello shutter scelto. Il percorso dei pixel include stabilizzazione, ritiming e trasformazioni già presenti all’ingresso dell’effetto.

Il movimento di camera viene stimato su punti distribuiti nel quadro. Per seguire mani, volti e altri elementi il motore cerca anche il moto locale a più scale, con precisione subpixel. Il confronto avanti e indietro permette una traiettoria curva quando i due lati sono coerenti. Ai bordi fra soggetto e sfondo il motore dà meno peso ai campioni con colore incompatibile. In Alta qualità, se il moto globale resta ambiguo, può consultare un’immagine più lontana su ciascun lato, fino a tre intervalli OFX. La sua geometria deve trovare riscontro nel vicino immediato. Le immagini lontane servono soltanto a stimare la traiettoria.

La posa già impressa viene cercata nei metadati compatibili della ripresa e nei bordi in movimento dell’immagine ricevuta. Una lettura stabile dai metadati e una stima ottica sufficientemente precisa consentono di dosare il mosso aggiuntivo. Se mancano entrambe, il motore assume una posa iniziale breve e lo segnala. Una posa originale più lunga del risultato desiderato limita quanto si può ottenere. Durante un fermo, un’occlusione, un taglio o un cambio di direzione rapidissimo, l’informazione disponibile può essere parziale. Alle estremità della clip è possibile lavorare con il solo vicino presente.

## Controllare un fotogramma

- **Verifica ultimo render** aggiorna **Fotogrammi utilizzati**. “Interi OFX · passo 40.00 ms” indica che i vicini usati distano una posa di timeline a 25 fps dal centro. “Intermedi OFX · passo 20.00 ms” indica che l’host ha fornito immagini a metà intervallo. “Guida” indica un contesto temporale più largo accettato per il movimento di camera.
- **Risultato verifica** riporta la posa obiettivo, la provenienza di quella iniziale quando disponibile e **ΔRGB P90**. Il valore è il novantesimo percentile della massima variazione RGB per punto su una griglia del render. Un movimento molto piccolo nello spazio può sfuggire a quella griglia. Con **Vista → Differenza RGB ×8** puoi osservare direttamente ogni pixel modificato. Riporta **Vista** su **Risultato** per l’export.
- Per un confronto con la versione precedente su una clip già elaborata, rigenera la cache del tratto e confronta lo stesso fotogramma al 100% nel viewer. Un frame servito dalla cache può precedere sia il cambio di versione sia l’ultimo aggiornamento del rapporto.

## Colore, prestazioni e retiming

**Valori manuali → Segnale in ingresso** deve corrispondere alla curva presente in quel punto della catena. Per un nodo che riceve DWG/DaVinci Intermediate seleziona **DaVinci Intermediate**. Se entra direttamente il girato Sony seleziona **Sony S-Log3**. Su immagini già trasformate in luce lineare seleziona **Lineare (scene-linear)**. Per altre curve log puoi usare i Color Space Transform di Resolve attorno all’effetto. Shutter calcola la media della luce e la riconverte nella curva scelta. Il tag della camera da solo non identifica una trasformazione già applicata.

**Anteprima → Fluida** usa una griglia di 16 pixel e fino a 16 campioni quando l’host segnala un render draft. **Alta qualità** usa sempre la griglia di 8 pixel. La modalità Cinema può arrivare fino a 192 campioni per una traiettoria lunga. Il numero si riduce per movimenti piccoli o quando un numero intero di pose acquisite copre lo shutter scelto. In assenza del flag draft il filtro usa Alta qualità anche in playback. Per un master, se la cache contiene immagini draft, imposta Alta qualità e usa un render fresco.

Su macOS il codice Metal incorporato costruisce le piramidi, calcola il flusso e integra il mosso. L’analisi del moto globale e della posa precede questo passaggio sulla CPU. L’OFX riceve immagini in memoria dell’host. Il motore riusa le pipeline e i buffer Metal e può ripiegare sulla CPU per immagini piccole o quando Metal è indisponibile. La build esegue una verifica CPU/Metal e scrive **dist/Shutter-Metal.txt** con i tempi sintetici Full HD e UHD.

**Compensa lo shutter nella speed ramp** permette di animare **Velocità clip (%)** quando si conosce la curva del retime. Shutter misura il moto che entra nell’effetto. Per lavorare dopo la rampa si può applicare Shutter all’esterno di una compound che contiene la clip ritimata. La compensazione manuale adatta il tempo di posa letto dalla camera alla velocità locale. Nella modalità Cinema il centro rimane quello richiesto da Resolve.

Per una cadenza creativa diversa da quella di timeline, scegli **Look · FPS e shutter → Manuale** e anima **FPS look** e **Shutter desiderato**. I precedenti preset per ripresa e consegna mantengono i loro indici nei progetti salvati. I preset con cadenza inferiore possono trattenere la posa per più fotogrammi di timeline.

## Stabilizzazione

**MASTER (%)** è il controllo da animare in Edit o Color. A 100 applica la correzione impostata, a 0 azzera la rotazione di stabilizzazione e lo zoom adattivo. Valori intermedi interpolano la rotazione per riga e il campo visivo. La correzione ottica del profilo e l’orientamento del file appartengono alla geometria di base.

**Fluidità massima** imposta quanto smorzare il movimento a MASTER 100. **Crop massimo (zoom %)** imposta il limite richiesto al calcolo adattivo di Gyroflow. A 110% la scala è 1,10× e resta circa il 91% della larghezza. Il limite riguarda lo zoom adattivo e il risultato dipende anche dalla correzione ottica. **Blocco orizzonte (%)** dosa il livellamento. Nel rapporto **Dati rilevati** trovi sorgente telemetrica, dimensioni, fps, conteggi IMU e ottica, prima distanza di fuoco valida e tempo di lettura del sensore quando disponibili. La prima distanza è informativa, non descrive la profondità della scena.

## Lettura automatica della ripresa

Applicare Stabilize a una clip con un originale accessibile. Il percorso proviene dalla proprietà della clip fornita da Resolve. Per forzare una nuova lettura usare **Leggi dati clip**. Il codice invalida la vecchia analisi e rilegge i dati dello stesso originale. Se Resolve non espone un file (per esempio alcuni contenitori compositi), il pannello indica il limite. I campi e la precisione dipendono da camera, modalità, firmware e lente. Il catalogo di calibrazione viene incorporato in compilazione. La patch al core elimina la scansione delle cartelle dei profili e il caricamento dei preset predefiniti dell’app Gyroflow. Per il montaggio serve il solo bundle compilato; la build dei sorgenti acquisisce ancora dipendenze e catalogo sulla macchina di sviluppo.

## Database dei metadati per clip (MecenaClipDB)

**mecena-clipdb** estrae da ogni originale giroscopio, accelerometro, orientamento integrato, posa, readout, dimensioni del sensore, focale, zoom, fuoco e diaframma, con lo stesso parser e le stesse calibrazioni di Stabilize. Il binario si trova in **MecenaMotion.ofx.bundle/Contents/Resources/**. Conviene lanciarlo all’ingest, quando le schede sono ancora collegate:

    /Library/OFX/Plugins/MecenaMotion.ofx.bundle/Contents/Resources/mecena-clipdb scan ~/Movies/MecenaClipDB /Volumes/SCHEDA_A

Una seconda scansione rilegge soltanto le clip nuove o modificate; `--force` le rilegge tutte. Ogni clip occupa una cartella **clips/<id>/** con questi file:

| File | Contenuto |
| --- | --- |
| `clip.json` | camera, ottica, video, posa e angolo shutter, readout, IMU, sensore in px e mm, intervalli di focale, fuoco, diaframma e zoom |
| `gyro.gyroflow` | progetto Gyroflow con i dati movimento incorporati, quello che Stabilize carica |
| `imu.csv` | campioni grezzi di giroscopio (°/s), accelerometro e magnetometro |
| `orientation.csv` | quaternione integrato nel tempo |
| `lens.csv` | per ogni campione ottico: focale, fuoco, f/T-stop, zoom, focale in pixel, centro ottico, sensore e pixel pitch |
| `frames.csv` | tempo e offset di cattura di ogni fotogramma |
| `metadata.json` | metadati del file senza le serie, compresi i dati specifici della camera |

L’elenco si trova in **index.json**. Il formato è descritto in `vendor/common/src/clipdb.rs`.

Stabilize cerca la clip nel database prima di leggere l’originale. I database consultati sono quelli registrati dalla scansione, quelli indicati da `MECENA_CLIPDB` e una cartella **MecenaClipDB** posta accanto agli originali o fino a cinque livelli sopra. La corrispondenza si cerca prima per percorso, poi per nome e dimensione e infine per nome senza i suffissi dei proxy (`_proxy`, `_prx`…). Due schede con la stessa numerazione si distinguono dalle cartelle in comune. Se nessun criterio basta, il plugin non sceglie. Funziona quindi anche con gli originali offline e con i proxy. **Dati rilevati** riporta «DB Mecena» e il riepilogo della clip.

**Adjustment clip su tutta la timeline.** Copia `Mecena ClipDB.py` (anch’esso in Resources) in `~/Library/Application Support/Blackmagic Design/DaVinci Resolve/Fusion/Scripts/Utility/`. Con la timeline aperta lancia **Workspace → Scripts → Mecena ClipDB**. Lo script aggiorna il database con gli originali raggiungibili e scrive in **timelines/** la mappa che associa ogni frame di timeline a una clip, al frame sorgente e alla velocità. La mappa diventa quella attiva. Mecena Stabilize su un adjustment clip legge, frame per frame, la clip visibile più in alto e la stabilizza con i suoi dati. Con più adjustment clip li distingue per durata. Dopo ogni modifica al montaggio rilancia lo script. Limiti: le speed ramp a velocità variabile non vengono seguite (la velocità costante sì), e le clip ridimensionate o riposizionate sotto l’adjustment clip ricevono una correzione pensata per il quadro intero. Il caso d’uso previsto è una timeline di proxy o originali a quadro pieno.

## Uso previsto in Edit e Color

La categoria **Mecena Motion** espone due effetti nello stesso binario OFX. Applicare **Mecena Stabilize** sulla clip e poi **Mecena Shutter**. Questa scelta lascia a Resolve il compito di rendere i fotogrammi adiacenti del primo stadio anche durante lo scrubbing o un render fuori ordine. Si può usare ogni effetto singolarmente. La lettura avviene dall’originale indicato da Resolve oppure, per rileggere dopo un relink, tramite il pulsante «Leggi dati clip» che interroga di nuovo Resolve. Il plugin usa il parser telemetrico di Gyroflow, le calibrazioni integrate e i fotogrammi passati dall’host. Il progetto non installa un’app, un interprete, script di menu o un secondo bundle. Non crea master intermedi. I dati della lente dipendono da camera, modalità e originale; una distanza di fuoco non equivale a una mappa di profondità.

**Sony e DJI con dati movimento**: applicare Stabilize e verificare stato, profilo e sincronismo, poi aggiungere Shutter. L’adattatore legge il frame sorgente quando Resolve lo espone. Se manca l’informazione, il tempo viene stimato dalla cadenza e dagli intervalli; una rampa arbitraria può produrre disallineamento. I timestamp VFR irregolari e le diverse modalità S&Q richiedono verifica su file reali.

**iPhone o clip senza gyro utilizzabile**: applicare Shutter e attivare «Stabilizzazione ottica leggera (senza gyro)». Questa prima modalità stima la traslazione globale da corrispondenze locali, conserva una panoramica a velocità costante e attenua gli scatti tra fotogrammi. I bordi sono estesi per campionamento. Rotazioni, soggetti che occupano gran parte del quadro e forte parallasse sono limiti di questa modalità.

**Retiming**: per rendere esplicito l’ordine, stabilizzare la clip interna e applicare Shutter al livello che riceve i fotogrammi già ritimati, ad esempio all’esterno di una compound clip. La prova in Resolve deve usare un riferimento alla stessa cadenza di consegna.

**Colore**: Shutter espone lineare, S-Log3 e DaVinci Intermediate. Impostare la curva effettivamente ricevuta dall’OFX. Per altri log usare trasformazioni interne a Resolve attorno al nodo Color per lavorare in scene-linear. Riconoscimento automatico dello spazio in ogni configurazione, virtual production e parità visiva con RSMB restano da validare o sviluppare.

## Prove incluse

La prova `tests/cinema.cpp` richiama le azioni OpenFX di descrizione, richiesta dei frame e render. La scena sintetica combina pan, tilt e roll con una mano articolata in movimento indipendente. La sorgente simula un’acquisizione a 50 fps e 90°. Il riferimento calcola direttamente la luce e la visibilità della stessa scena in 96 istanti distribuiti su 20 ms. In questo test l’host rifiuta tutte le richieste intermedie e presenta solo frame interi a 25 fps.

| Zona | Errore RGB medio senza effetto | Errore RGB medio con Cinema a 180° |
| --- | ---: | ---: |
| Sfondo | 0,04717 | 0,00822 |
| Interno della mano | 0,05787 | 0,02041 |
| Contorni e zone che si coprono o scoprono | 0,06565 | 0,04224 |

I valori sono errori assoluti medi in RGB lineare su un istante della prova. Le verifiche includono intermedi distinti, arrotondati, duplicati e miscelati, 100p su 23,976p a 135°, posa originale diversa, guida remota attraversata da un taglio e immagine ferma. Una mira a righe ripetute riproduce la partenza, l’arresto e l’inversione del moto con una zona ferma accanto. Su CPU l’errore medio in questi tre casi passa rispettivamente da 0,03304 a 0,01597, da 0,03299 a 0,01812 e da 0,01254 a 0,00252. I test preesistenti coprono reverse, ramp, cadenza, bypass e curve log. Sul sistema di sviluppo Linux sono stati eseguiti il motore CPU e l’host di prova. Lo script Mac ripete i test sul binario integrato e controlla Metal. La resa sulla panoramica Sony originale, il confronto con RSMB e i tempi in Resolve su M4 Pro richiedono un riscontro su quelle macchine e immagini.

## Provenienza

Adattatore e codice comune derivati da gyroflow/gyroflow-plugins, commit 1d01ee04ca862b1a73cd8e2a507cfd1e95c03315. Gyroflow core e telemetry-parser sono dipendenze di compilazione bloccate in vendor/openfx/Cargo.lock. La variante elimina il ponte fuscript e l’apertura dell’app esterna, registra i due descrittori in un binario e collega staticamente il codice C++ del mosso. Licenza del progetto GPL-3.0-or-later, header OpenFX con licenza BSD inclusa in SDK. Fonti di riferimento: https://github.com/gyroflow/gyroflow-plugins e https://github.com/gyroflow/gyroflow.
