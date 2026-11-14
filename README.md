# AR Lighting Study

Eine visionOS-App zur Untersuchung von AR-Licht aus **Environment Probes**. Die App analysiert die vom System bereitgestellte Umgebungs-Cubemap, erkennt darin helle Bereiche und setzt daraus geschätzte virtuelle Lichtquellen in einer RealityKit-Szene. Zusätzlich enthält sie einen Nutzer-Test mit Stapelaufgabe und Werkzeuge für technische Messungen.

## Funktionen

- Environment Probes live erfassen und als Cubemap visualisieren
- Durchschnittliche Luminanz, helle Regionen und deren Masken berechnen
- Richtung, Farbe, Intensität und – über die erkannte Raumgeometrie – eine plausible Position virtueller Lichtquellen schätzen
- Directional- und Spot-Lights, Schatten, Grounding Shadows, Occlusion und Image-Based Lighting vergleichen
- Probedaten speichern, erneut laden und mit anderen Geräten austauschen
- zeitliche Stabilität, Laufzeit und Performance messen
- einen geführten User Test mit mehreren Licht-Presets und Fragebogen durchführen

Die App benötigt World-Sensing-Berechtigungen. Handtracking wird nur für die optionale Schlaginteraktion verwendet.

## Starten

1. Projekt in Xcode öffnen und auf einem visionOS-Gerät oder im Simulator bauen.
2. Beim ersten Start die Berechtigung für **World Sensing** erlauben.
3. Über **Start** beginnt direkt der User Test. Über **Development Mode** stehen die Analyse- und Testwerkzeuge zur Verfügung.

Für realistische Messungen und Environment-Probes ist ein echtes Apple-Vision-Pro-Gerät nötig.

## Development Mode

Der Development Mode ist für Entwicklung, Debugging und reproduzierbare Versuche gedacht. Er startet die immersive Szene ohne den geführten Nutzerablauf und bietet folgende Bereiche:

- **Einstellungen:** Environment Light, geschätzte Lichter, Grounding Shadows, Occlusion, eigene IBL, Szenen-Rekonstruktion sowie Debug-Darstellungen ein-/ausschalten.
- **Probe-Fenster:** aktuelle Environment Probe, Luminanz, Vorschau, Import/Export und gespeicherte Datasets.
- **Masken-Fenster:** Bright-Region-Maske, erkannte Regionen und Analyse-Presets.
- **Licht-Menü:** Parameter für das geschätzte Licht, etwa Lichttyp, Anzahl, Farbe, Intensität, Schatten und Spot-Light-Einstellungen.
- **Zeitliche Stabilisierung:** Glättung und Schwellwerte für Position, Richtung, Farbe, Intensität und Schattenweichheit.
- **Device-Anchor-Fenster:** Gerätepose und World-Reference-Anker zur räumlichen Referenzierung prüfen.
- **Technische Tests:** Laufzeit, zeitliche Stabilität und Performance unter definierten Szenarien aufzeichnen.

## Daten speichern, importieren und teilen

### Environment-Probe-Dataset

Im Development Mode unter **Dataset speichern** wird die aktuelle Roh-Cubemap inklusive Metadaten gesichert. Sie kann über **Letztes Dataset laden** wiederverwendet oder über **Dataset importieren** eingelesen werden.

Nach dem Speichern steht **Dataset per AirDrop teilen** zur Verfügung. Die Teilen-Funktion kann auch für andere kompatible Ziele wie Dateien oder Mail verwendet werden. Ein Dataset enthält die Metadaten und die sechs Roh-Faces (`probe-metadata.json`, `probe-face-*.bin`) und eignet sich für reproduzierbare Analysen auf einem anderen Gerät bzw. im Simulator.

### Probe-Paket

Im Probe-Fenster erzeugt **Probe-Paket exportieren** eine handliche Auswertung mit:

- Environment-Cubemap als PNG (normale und Nearest-Neighbor-Vorschau)
- Bright-Region-Maske als PNG
- durchschnittlicher Luminanz als Textdatei

Danach kann das Paket mit **Probe-Paket per AirDrop teilen** übertragen werden. Im Simulator wird es zusätzlich in den Downloads-Ordner des Macs exportiert.

### Technische Testdaten

Die technischen Tests erzeugen CSV- und Textdateien und bieten nach Abschluss jeweils eine Teilen-Schaltfläche. Die Dateien werden außerdem im Dokumentenordner der App unter `TechnicalEvaluations/` abgelegt.

| Test | Zweck | Ergebnis |
| --- | --- | --- |
| Test 1 – Laufzeit & Probe-Updates | Misst über 60 Sekunden die Probe-Ankünfte und Dauer vollständiger Analysen. | `probe-arrivals.csv`, `analysis-times.csv`, `summary.csv`, `test-info.txt` |
| Test 2 – Zeitliche Stabilität | Vergleicht 60-Sekunden-Läufe ohne bzw. mit Stabilisierung; speichert alle zwei Sekunden Probe, Maske und Lichtparameter. | Timeline, Lichtparameter, Änderungsereignisse, Zusammenfassung sowie Dateien je Messschritt |
| Test 4 – FPS-Stresstest | Misst die RealityKit-Update-Rate mit unterschiedlichen Licht-/Schatten-Szenarien. | `frame-times.csv`, `summary.csv`, `test-info.txt` |

## User Test

Der normale **Start** führt in den User Test. Dort wird eine Stapelaufgabe mit wechselnden Licht-Presets durchgeführt:

1. Die Testperson löst die Stapelaufgabe in der immersiven Szene.
2. Mit **Next** wird der Fragebogen geöffnet.
3. Nach dem Fragebogen wechselt die App zum nächsten Preset und einer neuen Kartenabbildung.
4. Nach den geplanten Durchläufen kann die Testperson im Preset-Explorer eine bevorzugte Einstellung wählen. Diese Auswahl wird ebenfalls gespeichert.

Pro Fragebogen werden Zeitstempel, das aktive Licht-Preset, die Kennzeichnung für Zusatzdurchläufe und die Antworten gespeichert.

### User-Test-Daten herunterladen

Die zuverlässige Originaldatei einer Sitzung liegt im App-Dokumentenordner:

```text
Documents/LighttestQuestionnaireSessions/questionnaire-session-YYYY-MM-DD-HH-mm-ss.json
```

Zusätzlich schreibt die App für einen schnellen Zugriff:

```text
Documents/latest-questionnaire-session.json
```

So rufst du die Daten ab:

1. Verbinde das Headset mit dem Mac und öffne in Xcode **Window → Devices and Simulators**.
2. Wähle das Gerät und die App aus und lade den App-Container herunter bzw. öffne die App-Dokumente.
3. Kopiere die JSON-Datei aus `Documents/LighttestQuestionnaireSessions/` auf den Mac.

Ist der Dokumentenordner über die Dateien-App erreichbar, kann dieselbe JSON-Datei dort ausgewählt und über das Teilen-Menü – beispielsweise per AirDrop – verschickt werden. Für eine spätere Auswertung sollte die datierte Datei aus `LighttestQuestionnaireSessions/` verwendet werden; `latest-questionnaire-session.json` wird bei jedem neuen Speichervorgang überschrieben.


