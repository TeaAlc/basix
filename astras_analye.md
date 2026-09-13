# Aufgabenüberblick

## Ergebnis und Geltungsbereich

Basix lässt sich voraussichtlich am wirksamsten durch weniger unnötige Delegation, weniger ständig geladenes Regelwerk und eine aufgabenabhängige Reasoning-Stufe optimieren. Reines Kürzen einzelner Sätze reicht für eine Halbierung der Gesamtkosten wahrscheinlich nicht aus. Die besten Kandidaten beseitigen ganze zusätzliche Agentenstarts oder unnötig aufwendige Bearbeitungsschritte.

Analysiert am 13.09.2026, Ausgangscommit `2e73ef1`. Grundlage sind die kanonischen Quellen in `src/skills`, `src/agents`, `src/setup/developer_instruction.md`, zugehörige Validatorverweise, zwei voneinander abgegrenzte Quellanalysen und die unten dokumentierte Sitzungstelemetrie. Installierte `.agents`-Dateien wurden zum verpflichtenden Skill-Bootstrap gelesen, aber nicht als Produktnachweis verwendet; `.codex` wurde nicht als Produktquelle ausgewertet. Es wurden keine Basix-Produktregeln, Agenten oder Skills geändert und keine bezahlten Vergleichsläufe gestartet.

Die Analyse ist eine strukturelle Bewertung, kein nachgewiesener Geschwindigkeitsbenchmark. Die Empfehlungen beziehen sich auf Basix-eigene Regeln: Übergeordnete Plattformvorgaben kann Basix weder durch kürzere Formulierungen noch durch vermeintliche Ausnahmegenehmigungen aufheben.

## Wie die Schätzungen zu lesen sind

Jede Maßnahme nennt drei **hypothetische Planungsbandbreiten**, keine Messwerte und keine statistischen Konfidenzintervalle:

- **Kostenersparnis:** prozentuale Verringerung der gesamten Modellkosten eines betroffenen Auftrags einschließlich Root, Subagents, Ausgaben und Wiederholungen. Ohne aktuelle Preise ist kein Eurobetrag ableitbar.
- **Zeitersparnis:** prozentuale Verkürzung der gesamten Bearbeitungsdauer bis zum akzeptierten Ergebnis. Parallelisierung kann diese Größe verbessern, ohne Kosten zu sparen.
- **Qualitätsverlust:** relative Verschlechterung eines vorab festgelegten Qualitätsscores gegenüber dem bisherigen Ablauf. Bei einem Ausgangsscore von 80 bedeutet 5 % Verlust einen Score von 76; es bedeutet nicht fünf zusätzliche Prozentpunkte Fehlerquote.

Die Bandbreiten gelten nur für die jeweils genannte Aufgabenklasse, nicht für alle Basix-Aufträge. Außerhalb dieser Klasse kann der Nutzen null sein; Fehlklassifizierung kann Kosten und Fehler sogar erhöhen. Vertrauen bezeichnet die Sicherheit des Wirkmechanismus, nicht die Sicherheit der Zahlen. Die unteren Qualitätsverlustwerte sind möglich, aber nicht garantiert. Alle Prozentangaben sind fachliche Arbeitshypothesen aus den sichtbaren Abläufen; ein kausaler A/B-Nachweis fehlt.

Das Nutzerziel wird konservativ als **50 % weniger Kosten bei höchstens 5 % relativem Qualitätsverlust** interpretiert. 50 % mehr Ergebnisse pro Euro entsprächen bereits 33,3 % geringeren Stückkosten; eine Halbierung der Stückkosten ist die anspruchsvollere Auslegung. Für Berechtigungen, Datenverlust, Isolation und andere kritische Fehler ist kein zusätzliches Fehlerbudget vorgesehen.

## Was die Quellen tatsächlich zeigen

| Kanonische Quelle | Wörter | Bytes | Bedeutung |
| --- | ---: | ---: | --- |
| `src/setup/developer_instruction.md` | 2.116 | 14.062 | Umfangreicher allgemeiner Regelblock |
| `src/skills/basix/SKILL.md` | 708 | 5.186 | Bei jeder Basix-Aufgabe zu ladender Router |
| `src/skills/basix/references/agent-communication-contract.md` | 1.083 | 7.834 | Pflichtlektüre für native Agenten |
| `src/agents/native/basix-file-explorer.toml` | 494 | 3.725 | Suchrolle einschließlich Bootstrap und Metadaten |
| `src/agents/native/basix-miraculix.toml` | 425 | 2.978 | Begrenzte Beratung einschließlich Metadaten |
| `src/agents/native/basix-pager.toml` | 951 | 7.358 | Webentwicklung einschließlich Metadaten |
| `src/agents/native/basix-researcher.toml` | 403 | 2.937 | Recherche einschließlich Metadaten |
| `src/agents/native/basix-verifier.toml` | 988 | 7.362 | Prüfung einschließlich Metadaten |

Ermittelt mit `wc -w -c`. Wörter und Bytes sind keine Tokenmessung. TOML-Dateigröße ist zudem nicht identisch mit dem tatsächlich injizierten Prompt. Der Umfang sämtlicher Skill-Skripte sagt wenig über den Modellinput aus: Ein ausgeführtes Skript muss nicht vollständig gelesen werden.

Basix besitzt bereits sinnvolle Sparmechanismen: frische, begrenzte Delegationsaufträge ohne Gesprächsvererbung; Explorer mit gezielten Quellausschnitten; einmaliges Lesen je Kontext; bedarfsabhängige Referenzen und risikobasierte Prüfauswahl. Diese Mechanismen sollten erhalten bleiben. Siehe [Explorer-Suche](src/agents/native/basix-file-explorer.toml#L17), [Bootstrap](src/agents/native/basix-file-explorer.toml#L53) und [Entwicklungsregeln](src/skills/basix/references/developing-basix.md#L19).

## Priorisierte Maßnahmen

### M1 — Delegation nach erwartetem Gesamtaufwand entscheiden

**Befund:** Der Developer-Prompt erlaubt kleine Aufgaben bei Root, verlangt Delegation aber bereits bei mehr als zwei substanziellen Tool-Aufrufen, mehreren Schritten oder besonderem Fachwissen. Dieselbe Schwelle steht im Router. Drei kleine lokale Abfragen können deshalb einen zusätzlichen Agenten auslösen. Quellen: [Developer-Prompt](src/setup/developer_instruction.md#L70), [Router](src/skills/basix/SKILL.md#L69).

**Änderung:** Die starre Aufrufschwelle durch eine Entscheidung über den erwarteten Gesamtaufwand ersetzen. Root erledigt klar begrenzte Aufgaben direkt, wenn der relevante Kontext schon vorliegt und Start, Übergabe und Synthese voraussichtlich teurer wären. Breite lokale Erkundung, externe Recherche, nichttriviale Webentwicklung und erforderliche unabhängige Prüfung behalten ihre spezialisierten Routen. Ein Aufruflimit dient höchstens als Warnsignal für wachsenden Umfang.

**Warum das funktioniert:** Ein vermiedener Agentenstart beseitigt dessen Initialisierung, Pflichtlektüre, Kommunikationsschritte und die anschließende Interpretation durch Root. Der Nutzen stammt aus dem entfallenen Ablauf, nicht nur aus einem kürzeren Prompt. Bei breiter Recherche kehrt sich das Verhältnis um: Dort kann der günstige Explorer Root viel Input ersparen.

**Schätzung:** Bei kleinen, heute unnötig delegierten Aufgaben **15–35 % Kostenersparnis**, **20–45 % Zeitersparnis**, **0–2 % Qualitätsverlust**. Vertrauen: mittel. Ist Root deutlich teurer oder braucht es viele zusätzliche Aufrufe, kann die Maßnahme unwirtschaftlich sein.

**Absicherung:** Aufgaben nach Breite und Abhängigkeiten klassifizieren; tatsächliche Gesamtkosten einschließlich Root vergleichen. Bei unerwarteter Ausweitung einmalig einen klaren Restauftrag delegieren. Keine parallele Wiederholung derselben Suche.

### M2 — Developer-Prompt und Router in einen kleinen Kern und Pflichtmodule aufteilen

**Befund:** Der allgemeine Prompt enthält detaillierte Planbenennung, ADR-Lebenszyklen, Memory-Felder, Agentenhierarchie und Charakterpflege. Hierarchie und Delegation werden im Router erneut erklärt. Quellen: [Planregeln](src/setup/developer_instruction.md#L13), [ADR-Regeln](src/setup/developer_instruction.md#L27), [Memory](src/setup/developer_instruction.md#L40), [Agenten](src/setup/developer_instruction.md#L65), [Router](src/skills/basix/SKILL.md#L40).

**Änderung:** Im stets sichtbaren Kern nur Geltung, Prioritäten, Sicherheitsgrenzen, Zuständigkeit und präzise Ladebedingungen behalten. Dateinummerierung vor einer Plananlage laden; ADR-Lebenszyklusregeln vor einer ADR-Änderung; Memory-Schreibschema vor einer Memory-Änderung. Ein geladener Modulinhalt bleibt verbindlich. Das ADR-Verzeichnis bleibt vor Planung beziehungsweise Implementierung zu prüfen. Gemeinsame Regeln bekommen eine eindeutige kanonische Quelle; Bootstrap-Verweise bleiben bestehen.

**Warum das funktioniert:** Selten benötigte Verwaltungsdetails beanspruchen nicht bei jeder fachlichen Entscheidung Kontext. Weniger doppelte Formulierungen reduzieren außerdem widersprüchliche Auslegung. Auslagerung spart nur dann, wenn das Modul tatsächlich nicht gebraucht wird; pauschales Nachladen sämtlicher Module hätte keinen Vorteil und könnte zusätzliche Tool-Latenz verursachen.

**Schätzung:** Bei kurzen bis mittleren Aufträgen **5–18 % Kostenersparnis**, **3–12 % Zeitersparnis**, **0–1 % Qualitätsverlust**. Vertrauen: mittel. Bei stark gecachten Präfixen eher am unteren Rand.

**Absicherung:** Eine kleine Trigger-Matrix prüft für jeden Aufgabentyp die erforderlichen Module. Sicherheits- und Zuständigkeitsregeln nicht hinter unklaren Suchbegriffen verstecken. Nicht voraussetzen, dass ein Agent automatisch jeden Developer-Block erbt: Die garantierte Verfügbarkeit muss für Projekt-, globale und Plugin-Installation geprüft werden.

### M3 — Reasoning-Aufwand für Pager und Verifier nach Schwierigkeit staffeln

**Befund:** Beide Rollen verwenden fest `gpt-5.6-luna` mit `xhigh`. Die Klassifikationsreferenz unterscheidet zugleich `high` und `xhigh`. Validator und Tests erzwingen derzeit die festen Einstellungen. Quellen: [Pager](src/agents/native/basix-pager.toml#L7), [Verifier](src/agents/native/basix-verifier.toml#L7), [Klassifikation](src/skills/basix-agent-authoring/references/model-classification.md#L18), [Validator](src/skills/basix-agent-authoring/scripts/validate.py#L350).

**Änderung:** Für überschaubare Aufgaben eine explizit unterstützte `high`-Variante erproben. Root klassifiziert die Aufgabe anhand Abhängigkeiten, Unsicherheit und Fehlerwirkung. `xhigh` bleibt für komplexe Fehleranalyse, Sicherheitsgrenzen, viele Schichten und schwierige Verifikation. Ein bloßer Hinweis im Auftrag garantiert keine Änderung der tatsächlichen Konfiguration; das Routing muss technisch unterstützt und nachgewiesen sein.

**Warum das funktioniert:** Niedrigere Reasoning-Stufen können den Aufwand für interne Analyse senken, wenn das Problem keine tiefe Suche verlangt. Eine begrenzte Aufgabe verliert dadurch möglicherweise wenig Qualität. Die Ersparnis verschwindet, sobald eine schwächere Erstbearbeitung zusätzliche Korrekturzyklen verursacht.

**Schätzung:** Bei passenden Routineaufträgen dieser Rollen **10–30 % Kostenersparnis**, **15–35 % Zeitersparnis**, **1–5 % Qualitätsverlust**. Vertrauen: niedrig bis mittel; dies ist ein besonders messbedürftiger Hebel.

**Absicherung:** Konfiguration, Validator, Rollentests, Dokumentation und Smoke-Skripte gemeinsam anpassen. Bei fehlgeschlagenen Abnahmekriterien oder neuer Unsicherheit auf `xhigh` eskalieren und den Wiederholungsaufwand mitrechnen. Miraculix und seine durch ADR 0002 gebundene Konfiguration sind nicht Gegenstand dieser Maßnahme.

### M4 — Kommunikationsschema vereinfachen und mechanisch erzeugen

**Befund:** Contract 1.4 verlangt zehn feste Top-Level-Felder, Sequenzen, Zyklusrevisionen, vollständige Planstände in Statusmeldungen und eine gesonderte Ankündigung angeforderter Berichte. Quellen: [Schema und Zyklen](src/skills/basix/references/agent-communication-contract.md#L23), [Status](src/skills/basix/references/agent-communication-contract.md#L44), [Berichte](src/skills/basix/references/agent-communication-contract.md#L70).

**Änderung:** Zunächst eine gemeinsame, validierte Nachrichtenerzeugung prüfen, die feste Felder und Zähler automatisch ergänzt. In einer ausdrücklich neuen Vertragsversion könnten Statusmeldungen nur Änderungen enthalten und Berichtsankündigungen mit dem Ergebnis zusammenfallen. Endergebnisse bleiben vollständig; Blocker, Berechtigungsfragen, Elternzuständigkeit und Freeze-Regeln bleiben erhalten. Ohne verfügbare technische Unterstützung keine vermeintliche Automatisierung behaupten.

**Warum das funktioniert:** Das Modell muss weniger Protokollzustand formulieren und reproduzieren. Weniger Nachrichten bedeuten weniger zusätzliche Modellrunden und weniger Text, den Eltern auswerten müssen. Ein Statusdelta ist nur dann günstiger, wenn der Empfänger den letzten Plan zuverlässig kennt.

**Schätzung:** Bei Aufträgen mit mehreren Status- oder Berichtsrunden **3–12 % Kostenersparnis**, **3–15 % Zeitersparnis**, **0–2 % Qualitätsverlust nach bestandener Protokollprüfung**. Vertrauen: niedrig bis mittel. Bei kurzen Aufträgen ohne Zwischenmeldungen ist der Nutzen gering.

**Absicherung:** Sequenzfehler, verlorene Meldungen, Fortsetzungen, Berechtigungsblocker und Endergebnisse negativ testen. Keine Kürzung des derzeit verpflichtenden Vertrags durch eigenmächtiges Weglassen von Abschnitten. Ein optionales technisches Hilfsmittel darf keine neue fragile Pflichtabhängigkeit ohne Rückfallmöglichkeit schaffen.

### M5 — Bestehende Fortsetzungsmöglichkeiten gezielt nutzen

**Befund:** Der Vertrag erlaubt eine Fortsetzung bei unverändertem Auftrag und Prüfziel; geänderte Dateien, Kriterien oder Remediation verlangen einen frischen Agenten. Quelle: [Fortsetzung](src/skills/basix/references/agent-communication-contract.md#L32).

**Änderung:** Bei einer fehlenden Erläuterung zum gleichen unveränderten Ergebnis `followup_task` mit Fortsetzungsgrund verwenden, statt einen neuen Agenten denselben Sachverhalt recherchieren zu lassen. Root verlangt beim ersten Auftrag bereits Quellen, Grenzen und Abnahmeevidenz, damit Rückfragen selten bleiben.

**Warum das funktioniert:** Vorhandene Quellerkenntnisse müssen nicht erneut erarbeitet werden. Fortsetzungen machen alten Kontext jedoch nicht kostenlos: Er kann erneut als Input zählen. Der verlässlichere Vorteil ist die vermiedene Recherche; bei langem oder irrelevanten Altverlauf kann ein Neustart günstiger sein.

**Schätzung:** Bei Aufträgen mit einer ansonsten neu gestarteten Rückfrage **5–20 % Kostenersparnis**, **10–25 % Zeitersparnis**, **0–1 % Qualitätsverlust**. Vertrauen: mittel. Für Aufträge ohne Rückfrage: kein Effekt.

**Absicherung:** Nur unveränderte Ziele, Dateien und Kriterien; keine Wiederverwendung eines Verifiers nach Änderungen. Die bestehende Regel reicht aus, eine Lockerung der Freeze-Grenze ist nicht nötig.

### M6 — Skill-Ladebedingungen präzisieren und Wiederholungen entfernen

**Befund:** `basix-agent-authoring` lädt Klassifikation und Vertrag und wiederholt Teile der Modell- und Hierarchieregeln. `configure-tmux` enthält ähnliche Hinweise wie seine Referenzen, lädt diese teilweise aber bereits gezielt. Quellen: [Authoring](src/skills/basix-agent-authoring/SKILL.md#L13), [tmux-Diagnose](src/skills/configure-tmux/SKILL.md#L26), [tmux-Regeln](src/skills/configure-tmux/SKILL.md#L61), [Client-Verhalten](src/skills/configure-tmux/references/client-behavior.md#L21).

**Änderung:** Pro Skill einen kurzen Ablauf und eine Tabelle „Situation → erforderliche Referenz“ verwenden. Begründungen und seltene Varianten in genau einer Referenz halten. Die bereits vorhandene bedarfsabhängige Ladung ausdrücklich beibehalten. Beim Authoring bleibt das vollständige Verständnis der betroffenen Agenten- und Kommunikationsregeln Voraussetzung einer Änderung.

**Warum das funktioniert:** Der Agent verarbeitet nur die zu seinem konkreten Problem gehörenden Varianten. Eine kanonische Regelquelle verhindert zudem, dass leicht abweichende Wiederholungen zusätzliche Interpretation oder Rückfragen auslösen. Skripte auszuführen statt vollständig zu lesen spart nur dort Input, wo keine Codeanalyse nötig ist.

**Schätzung:** Bei betroffenen Skill-Aufträgen **3–12 % Kostenersparnis**, **2–10 % Zeitersparnis**, **0–2 % Qualitätsverlust**. Vertrauen: mittel. Wer bereits nur nötige Referenzen liest, profitiert weniger.

**Absicherung:** Diagnosefälle für Clipboard, erweiterte Tasten, mehrere Konfigurationen und Terminalvarianten gegen die Referenzauswahl prüfen. Eine tatsächlich geänderte tmux-Implementierung benötigt ihre gezielte Suite; für diesen Bericht wurde sie nicht ausgeführt.

### M7 — Experience-Trigger auf tatsächliche Retrospektiven zuschneiden

**Befund:** Der Experience-Skill reagiert auch auf Token-Effizienzberatung, verlangt jedoch ausschließlich eine Retrospektive sichtbarer Sitzungsarbeit mit vier festen Abschnitten. Eine allgemeine Produktanalyse wie diese passt nur teilweise dazu. Quelle: [Experience-Skill](src/skills/basix-experience/SKILL.md#L1).

**Änderung:** Retrospektive und strukturelle Optimierungsanalyse im Trigger unterscheiden. Den vollen Feedback-/Telemetrieablauf nur bei Sitzungsbewertung laden; eine Produktanalyse bekommt ein passendes leichtes Berichtsformat. Natürlichsprachliche explizite Nutzerwünsche bleiben auslösbar. Nicht pauschal alle impliziten Aufrufe abschalten.

**Warum das funktioniert:** Eine fachlich passende Route vermeidet unnötige Feedbacksektionen und verhindert, dass die eigentliche Analyse in ein fremdes Schema gezwängt wird. Weniger Formatkonflikte reduzieren sowohl Ausgabeaufwand als auch Nacharbeit.

**Schätzung:** Bei heute fehlgeleiteten Analyseaufträgen **3–10 % Kostenersparnis**, **3–10 % Zeitersparnis**, **0–1 % Qualitätsverlust**. Vertrauen: mittel; Aufgabenpassung kann sogar steigen, wird hier aber nicht als gesicherter Qualitätsgewinn verbucht.

**Absicherung:** Kleine Sammlung positiver und negativer Auslösebeispiele testen: Sitzungsfeedback, allgemeine Basix-Analyse, konkrete Agentenänderung und bloße Erwähnung von Tokens.

### M8 — Für kleine Aufgaben den Verwaltungsanteil der Planung begrenzen

**Befund:** Planformat, Dateinummerierung, Archivierung, ADR-Prüfung und Memory-Abschluss erzeugen Schritte unabhängig von der Größe der fachlichen Aufgabe. Quelle: [Planung](src/setup/developer_instruction.md#L13). ADR 0001 bindet die Struktur vorhandener Pläne.

**Änderung:** Für kleine Aufgaben höchstens einen kurzen, in sich vollständigen Plan mit einer Phase anlegen; nummerierte Aufgaben, QS und Learnings beibehalten. Wiederholte Erklärung derselben Planung in Datei, Chat und Agentenauftrag vermeiden. Eine spätere Ausnahme von der Plananlage nur separat prüfen, wenn der bestehende Regelrahmen sie tatsächlich verlangt; sie ist für diese erste Optimierung nicht erforderlich.

**Warum das funktioniert:** Bei kleinen Änderungen können Verwaltungsrunden einen großen Anteil der Bearbeitung ausmachen. Eine einzige klare Phase enthält dieselben Abnahmekriterien, verlangt aber weniger Zwischenpflege und Textproduktion.

**Schätzung:** Bei kleinen Dokumentations- oder Routineaufträgen **3–12 % Kostenersparnis**, **5–15 % Zeitersparnis**, **0–1 % Qualitätsverlust**. Vertrauen: mittel. Bei großen Vorhaben kaum relevant.

**Absicherung:** Abhängigkeiten oder unterschiedliche Risikoflächen weiterhin in eigene Phasen trennen. Kein Verzicht auf erforderliche QS oder den überprüften Abschluss. [ADR 0001](.basix/adrs/ADR_0001_plan-phase-tasks-and-learnings.md) bleibt unverändert.

### M9 — Memory stärker auf wiederverwendbares Wissen verdichten

**Befund:** Das aktuelle Memory wird vollständig zu Sitzungsbeginn gelesen und enthält zahlreiche detaillierte Podman-/Scrapling-Fallregeln, die für diese Analyse überwiegend nicht relevant waren. Die Regeln erlauben bereits Kuratierung, Zusammenführung und Löschung. Quellen: [.basix/memory.toml](.basix/memory.toml), [Memory-Vertrag](src/setup/developer_instruction.md#L40).

**Änderung:** Innerhalb des vorhandenen Schemas ähnliche Spezialfälle zu kurzen, handlungsleitenden Einträgen zusammenführen; dauerhaft dokumentierte Detailbeweise über konkrete Repository-Verweise auffindbar halten. Aktive Nutzerregeln und unersetzliche Sicherheitswarnungen bewahren. Selten gebraucht bedeutet bei Sicherheitswissen nicht automatisch unwichtig.

**Warum das funktioniert:** Weniger irrelevante Details verringern den Startkontext und die Wahrscheinlichkeit, dass fachfremde Regeln die Aufgabe unnötig erweitern. Der Nutzen ist begrenzt, wenn der Startkontext gut gecacht ist oder die Details bei der nächsten Aufgabe wieder gesucht werden müssen.

**Schätzung:** Bei fachfremden Kurzaufträgen **1–5 % Kostenersparnis**, **0–4 % Zeitersparnis**, **0–2 % Qualitätsverlust**. Vertrauen: niedrig bis mittel.

**Absicherung:** Zusammengeführte Regeln an früheren Fehlerfällen prüfen; keine Geheimnisse, keine pauschale Löschung nach Alter. Keine Änderung des Memory-Layouts als Nebenprodukt einer bloßen Textkürzung.

### M10 — Prüfungen konsequent nach verändertem Fehlerrisiko auswählen

**Befund:** Die Entwicklungsreferenz fordert bereits passende deterministische Tests, eine begründete Gate-Auswahl und teure Aggregationen erst am eingefrorenen Ergebnis. Quelle: [Risikobasierte Gates](src/skills/basix/references/developing-basix.md#L31).

**Änderung:** Diese bestehende Regel mit konkretem Änderungsumfang anwenden: fokussierte Tests nach Korrekturen, abhängige Aggregate einmal nach Abschluss, unabhängige Prüfungen nur bei isolierten Ressourcen parallel. Für einen Bericht genügen Dokument- und Belegprüfungen; Produktlaufzeittests decken dessen Fehlerrisiko nicht ab.

**Warum das funktioniert:** Wiederholt ausgeführte, unveränderte Testflächen erzeugen Wartezeit ohne zusätzliche Fehlerabdeckung. Die Auswahl entlang der tatsächlichen Abhängigkeiten bewahrt relevante Qualität und vermeidet sachfremde Prüfungen.

**Schätzung:** Bei heute überprüften oder mehrfach aggregierten Entwicklungsaufträgen **0–8 % Modellkostenersparnis**, **10–35 % Zeitersparnis**, **0–1 % Qualitätsverlust**. Vertrauen: mittel. Wenn Basix die Regel bereits vollständig umsetzt, entsteht kein zusätzlicher Gewinn. Tool-/Rechenkosten wären getrennt zu messen.

**Absicherung:** Sicherheits-, Installer- und Runtime-Gates niemals allein wegen Laufzeit entfernen. Geänderte Kommunikationsnormen benötigen die vorgeschriebene eingefrorene unabhängige Prüfung. Laufende beziehungsweise fehlgeschlagene Prüfungen verhindern weiterhin den Commit.

### M11 — Agentenaufträge und Rückgaben auf entscheidungsrelevante Evidenz begrenzen

**Befund:** Explorer sollen bereits belegte, abgegrenzte Antworten geben. Vollständige Ergebnisse und selbsttragende Aufträge sind vorgeschrieben; feste universelle Kurzlimits für jede Aufgabe wären damit unvereinbar. Quellen: [Explorer-Antwort](src/agents/native/basix-file-explorer.toml#L44), [vollständiger Abschluss](src/skills/basix/references/agent-communication-contract.md#L80).

**Änderung:** Aufträge nach dem Muster „Frage, Besitzbereich, bekannte Fakten, Ausschlüsse, Abnahme, erforderliche Belege“ formulieren. Im Ergebnis zuerst Entscheidung und Belege, dann nur relevante Grenzen. Ein weiches Umfangsbudget je Aufgabe setzen, mit ausdrücklicher Ausnahme für notwendige Beweise und Fehler. Root liest delegierte Quellbestände nicht noch einmal vollständig; widersprüchliche Einzelangaben werden gezielt geprüft.

**Warum das funktioniert:** Präzise Grenzen verhindern Nebenrecherchen. Eine kompakte evidenzhaltige Rückgabe spart Ausgabe beim Kind und erneuten Input beim Elternagenten. Das spart besonders dann, wenn mehrere Ergebnisse zusammengeführt werden; ein zu knappes Ergebnis erzeugt hingegen Rückfragen.

**Schätzung:** Bei breiten Analysen mit sonst langen Rückgaben **3–12 % Kostenersparnis**, **3–12 % Zeitersparnis**, **0–2 % Qualitätsverlust**. Vertrauen: mittel.

**Absicherung:** Unsicherheit, Gegenbeispiele und belegte Grenzen dürfen nicht dem Wortbudget geopfert werden. In dieser Sitzung war die gezielte Prüfung der Wort-/Byte-Zuordnung sinnvoll; die gesamte Quellanalyse erneut auszuführen wäre unnötig gewesen.

### M12 — Vollständige Abläufe messen, bevor das 50-%-Ziel behauptet wird

**Befund:** `run-file-explorer-benchmark.sh` extrahiert nur den markierten Suchabschnitt und startet mit `--ignore-user-config --ignore-rules`; Router- und Vertragsbootstrap sind damit kein Bestandteil dieses Prompts. Das Pager-Skript übernimmt dagegen die vollständigen Agentenanweisungen und erzwingt `xhigh`. Quellen: [Explorer-Benchmark](src/scripts/run-file-explorer-benchmark.sh#L29), [Pager-Smoke](src/scripts/run-pager-smoke.sh#L43).

**Änderung:** Den fokussierten Suchbenchmark behalten, daneben einen kontrollierten Vergleich des vollständigen installierten Ablaufs mit Root, Agentenstart, Pflichtlektüre, Kommunikation, Abnahme und möglichen Korrekturen vorsehen. Varianten und Aufgaben müssen identische Ausgangsstände verwenden. Modell- und Laufzeitkonfiguration, Cachebedingungen und Preisstand protokollieren.

**Warum das funktioniert:** Nur eine Messung der gesamten Kette erkennt, ob ein billigerer Teil durch zusätzlichen Elternaufwand oder mehr Korrekturen überkompensiert wird. Der vorhandene Suchbenchmark kann Suchqualität prüfen, aber allein keinen Basix-Gesamtgewinn beweisen.

**Schätzung:** **0 % unmittelbare Kostenersparnis**, **0 % unmittelbare Zeitersparnis**, **0 % beabsichtigter Qualitätsverlust am Produkt**. Der Vergleich verursacht zunächst zusätzliche Kosten und Zeit. Sein Nutzen liegt in der Auswahl wirksamer Maßnahmen und dem Verwerfen schädlicher Varianten; dafür wäre eine konkrete Einsparungszahl ohne Versuch spekulativ. Vertrauen in diesen Messmechanismus: hoch.

**Absicherung:** Wiederholungen, negative Fälle und vollständige Kosten fehlgeschlagener Versuche aufnehmen. Keine aktuellen Modellpreise oder tatsächliche Plattformunterstützung aus den Modellnamen im Repository ableiten.

## Wie realistisch sind 50 %?

Für kleine, bisher unnötig delegierte oder übermäßig geprüfte Aufgaben ist eine Halbierung plausibel genug für einen Versuch. Für bereits fokussierte Explorer-Suchen oder komplexe Sicherheitsarbeit ist sie durch diese Analyse nicht belegt. Einzelgewinne sind nicht addierbar: M1 entfernt einen Agenten, dessen Prompt M2 sonst verkürzen würde; M4 und M11 betreffen teilweise dieselben Nachrichten.

Ein rein illustratives Rechenbeispiel: Drei voneinander unabhängige Reduktionen von 25 %, 20 % und 15 % auf den jeweils verbleibenden Aufwand ergeben `1 − 0,75 × 0,80 × 0,85 = 49 %`. Das ist keine Prognose für dieses Repository. Beträgt der optimierbare Anteil eines Auftrags nur 20 %, können selbst vollständig beseitigte Kosten dieses Anteils insgesamt höchstens 20 % sparen.

Ebenso dürfen Qualitätsverluste nicht addiert oder als unabhängig behandelt werden. Drei einzeln akzeptable Maßnahmen können in Kombination wichtige Informationen entfernen. Die Gesamtkombination muss dieselbe Qualitätsgrenze erfüllen.

## Empfohlener Vergleich und Reihenfolge

Zuerst M12 als Messgrundlage herstellen. Danach M1 und M2 separat prüfen; sie greifen am allgemeinen Pflichtaufwand an. M5, M6, M7, M8, M9, M10 und M11 nach Häufigkeit der betroffenen Aufgaben priorisieren. M3 separat wegen des größeren Qualitätsrisikos testen; M4 wegen des geänderten Protokolls zuletzt. Diese Reihenfolge ist eine Umsetzungsempfehlung, kein in dieser Sitzung ausgeführter Produktumbau.

Ein praktikabler erster Versuch umfasst etwa 30 feste Aufgaben aus sechs Gruppen: lokale Kurzdiagnose, umfangreiche Quellsuche, Skillpflege, Webimplementierung, Verifikation und komplexe Grenzfälle. Je Variante mindestens drei Wiederholungen mit identischen Arbeitsständen; Variantenreihenfolge wechseln und Cachezustand soweit beobachtbar erfassen. Diese Stichprobe ist ein Pilot und kein Nachweis seltener Sicherheitsfehler.

Vorher Abnahmekriterien festlegen und den Score beispielsweise aus funktionaler Richtigkeit (50 %), Vollständigkeit (25 %), Belegtreue (15 %) und Wartbarkeit/Verständlichkeit (10 %) bilden. Kriterien müssen zur Aufgabenklasse passen; sicherheitskritische Verstöße sind separate Ausschlusskriterien. Ergebnisse verblindet beurteilen, nicht nur vom ausführenden Agenten selbst bewerten lassen.

Kosten je akzeptiertem Ergebnis, Median und hohe Perzentile der Laufzeit, Nacharbeitsrate, Vertragsverstöße und Qualität je Aufgabenklasse auswerten. Eine Variante wird erst übernommen, wenn ihr Vorteil über Wiederholungen stabil ist und die Qualitätsgrenze auch pro Klasse eingehalten wird. Ein unsicherer Pilot rechtfertigt weitere Messung, keine Behauptung eines nachgewiesenen Verlusts unter 5 %. Die kombinierte Variante anschließend gesondert vergleichen.

Bei einer späteren Umsetzung bleiben aktive ADRs bindend. Die hier vorgeschlagene kompakte Planung erhält ADR 0001; Miraculix bleibt gemäß ADR 0002 unverändert. Ein tatsächlicher Konflikt mit einem ADR verlangt vor der Umsetzung die geregelte Entscheidung. Vertrag, Validatoren, statische Assertions, Installation und Dokumentation müssen bei normativen Änderungen zusammenpassen.

# Skill-Feedback

Mit Skill `basix` war ich zufrieden. Der Router stellte die kanonischen Quellen und die Trennung von Laufzeitinstallation und Produktbelegen klar; die Entwicklungsreferenz ermöglichte eine angemessene Prüfauswahl. **Die wichtigste Verbesserung ist ein kleinerer allgemeiner Regelkern mit eindeutigen Ladebedingungen.** Die Analyse zeigte zudem, dass manche ausgelagerten Regeln im Developer-Prompt erneut formuliert werden.

Der Bericht erweitert die vorgeschriebene Sitzungsretrospektive um die vom Nutzer verlangte Produktanalyse. Bewertungen der anderen verfügbaren Skills als tatsächlich ausgeführte Workflows wären nicht gerechtfertigt; deren Quelltexte wurden untersucht, ihre Fachabläufe aber nicht erprobt.

# Subagent-Feedback

Mit Agent `astra_skills_audit` (`basix_file_explorer`) war ich zufrieden. Er lieferte abgegrenzte Quellenhinweise und erkannte bereits vorhandene bedarfsabhängige Referenzladung. Einige Vorschläge mussten eingeschränkt werden: Ein späteres Laden des Vertrags hilft einem Agenten nicht, wenn er ihn bereits vor seiner ersten Pflichtnachricht benötigt. **Die wichtigste Verbesserung ist, Sparvorschläge gegen den tatsächlichen ersten Nutzungspunkt einer Pflichtregel zu prüfen.**

Mit Agent `astra_agents_prompt_audit` (`basix_file_explorer`) war ich zufrieden. Er identifizierte die starre Delegationsschwelle und die Kopplung der Reasoning-Stufe an Validatoren. Seine Größenangaben bezeichneten Bytes fälschlich als Wörter; die Tabelle oben wurde deshalb durch eine gezielte Messung korrigiert. **Die wichtigste Verbesserung ist eine explizite Einheitenprüfung bei quantitativen Befunden.**

Beide sichtbar gelieferten Endantworten waren freier Text statt des verlangten Contract-1.4-JSON. Daraus folgt ein belegter Formatmangel der sichtbaren Übergabe, aber keine vollständige Aussage über sämtliche internen Nachrichten. Die Ergebnisse waren fachlich verwertbar; diese Sitzung belegt keine vollständige Protokollkonformität und keinen gemessenen Vorteil der Delegation gegenüber einer einzelnen Bearbeitung.

# Tokenverbrauch

Quelle: `PYTHONDONTWRITEBYTECODE=1 python3 src/skills/basix-experience/scripts/collect-token-usage.py --format json`, Schema 2, Status `ok`, Snapshot **2026-09-13 18:44:37 UTC**. Dies ist eine Zwischenaufnahme nach den beiden Quellanalysen, vor der vollständigen Berichtserstellung; kein Endverbrauch und kein repräsentativer Produktbenchmark. Es wird ausschließlich dieser Collector-Snapshot verwendet, ohne Daten aus anderen Quellen hinzuzuaddieren.

| Metrik | Wert |
| --- | ---: |
| Input-Tokens | 772.640 |
| Reasoning-Tokens | 991 |
| Output-Tokens | 7.437 |
| Cache-Trefferrate | 87,2 % — abgeleitet aus 673.536 / 772.640 |

Die Zähler enthalten kumulativ wiederholt verarbeiteten Input; sie beschreiben nicht 772.640 unterschiedliche Tokens im Kontext. Reasoning wird separat ausgewiesen und hier nicht zusätzlich auf Output aufgeschlagen. Aus dem Cacheanteil folgt keine gleich hohe Kostensenkung: Cacheinput, ungecachter Input und Ausgabe müssen mit ihren tatsächlichen jeweiligen Preisen gewichtet werden. Eine Preisabfrage wurde für diese lokale Strukturanalyse nicht durchgeführt.

Qualitativ sichtbare Aufwandstreiber waren wiederholter Kontext über mehrere Runden, zwei frische Agentenkontexte, Regel- und Quellenlektüre sowie die Synthese. Die Telemetrie liefert keine belastbare Zuordnung einzelner Kostenanteile zu diesen Ursachen. Die anfängliche Aufwandsschätzung unter 100.000 Input-Tokens war bereits in der ersten Zwischenmessung überschritten; der Arbeitsplan wurde entsprechend korrigiert. Auch das spricht für gemessene kumulative Kosten statt Schätzungen aus Textlängen.

Die fünf wichtigsten Spargelegenheiten aus der sichtbaren Sitzung:

| Rang | Ursache | Maßnahme | Erwarteter Effekt |
| --- | --- | --- | --- |
| 1 | Starre Delegationsschwelle neben einer allgemeinen Kostenregel | M1: Entscheidung am Gesamtaufwand ausrichten | Weniger Starts und Übergaben bei kleinen Aufgaben |
| 2 | Allgemeine Verwaltungsregeln und wiederholte Routingdetails | M2: Kern und bedingt geladene Pflichtmodule | Weniger irrelevanter Input je Kontext |
| 3 | Feste hohe Reasoning-Stufe trotz unterschiedlicher Schwierigkeit | M3: kontrollierte Aufwandsstaffelung | Weniger Analyseaufwand bei passenden Routinefällen |
| 4 | Umfangreicher Kommunikationszustand und sichtbare Formatabweichungen | M4: validierte Erzeugung und kompaktere Vertragsversion | Weniger Protokollarbeit und mögliche Korrekturrunden |
| 5 | Breite Übergaben mit einer korrigierungsbedürftigen Zahlenangabe | M11: präzise Evidenzformate einschließlich Einheiten | Weniger Synthese- und Nachprüfaufwand |

**Priorisierte nächste Produktänderung:** M1, die kostenabhängige Delegationsentscheidung, zuerst gegen einen vollständigen Referenzablauf messen. Sie kann einen ganzen zusätzlichen Ablauf vermeiden und bietet deshalb mehr Hebel als bloße Satzkürzung; Umfangsgrenzen und Fachrouten begrenzen das Qualitätsrisiko.
