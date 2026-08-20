# Analyse : test de démarrage avec fix USB (téléphone connecté avant lancement du DHU)

## Contexte

Log analysé : `20260820-test-lancement-dhu.log`
Build : `aa-proxy-rs` `20260820_090313`, git `f338e53-br#90dfa96`
Branche : `fix/usb-accessory-race` (fix `tokio_main` break-type + fix `usb_accessory_ready`, tous deux appliqués)
Téléphone : Pixel 9 (`C0:1C:6A:6C:1E:5A`), mode `bt_wireless_proxy_mode = car-wifi-mitm`
Scénario de test : `aa-proxy-rs` est lancé, le téléphone se connecte (BT + Wi-Fi + USB accessory), **puis** le DHU (Desktop Head Unit) est lancé manuellement côté PC (annotation `JE LANCE ICI LE DHU` dans le log original). La session est arrêtée volontairement par `Ctrl+C` en fin de test.

Objectif : vérifier que le fix `usb_accessory_ready` (synchronisation entre le switch du gadget USB et l'ouverture de `/dev/usb_accessory`) tient dans un ordre de démarrage différent des tests précédents — ici la tête d'unité (DHU) arrive *après* que le téléphone soit déjà connecté, au lieu d'être déjà présente.

## 1. Constat à partir des logs

```text
09:43:56.421  bluetooth: 🧲 Trying to connect to: C0:1C:6A:6C:1E:5A (Pixel 9), attempt: 1/3
09:43:56.840  bluetooth: 🔗 Successfully connected to device: C0:1C:6A:6C:1E:5A (Pixel 9)
09:43:57.269  bluetooth: 📨 stage #1 of 5: Sending WifiStartRequest frame to phone...
09:43:57.803  bluetooth: 📨 stage #5 of 5: Received WifiConnectStatus frame from phone (⏱️ 511 ms)
09:43:57.961  proxy:     📳 TCP server: new client connected: 10.0.0.5:60170
09:43:57.964  proxy:     🧪 bt-wireless-proxy car-wifi-mitm: PHONE TCP accepted on MD listener; commit barrier seq=1
09:44:00.021  usb:       🔌 USB Manager: Switched to accessory gadget
09:44:00.021  proxy:     📂 Opening USB accessory device: /dev/usb_accessory
09:44:00.021  proxy:     ♾️ Starting to proxy data between HU and MD...

        --- DHU lancé manuellement ici ---

[2157.558]    dwc2 fe980000.usb: new device is high-speed
[2157.616]    android_work: sent uevent USB_STATE=CONNECTED
[2157.751]    dwc2 fe980000.usb: new device is high-speed
[2157.997]    dwc2 fe980000.usb: new address 46
[2158.014]    android_work: sent uevent USB_STATE=CONFIGURED

09:44:19.904  main:  received Ctrl+C/SIGINT, attempting clean disconnect...
09:44:19.905  main:  signal exit: initiating clean disconnect
09:44:19.905  main:  signal exit: no active session tx, skipping ByeBye
09:44:19.905  main:  signal exit: exiting process after teardown
```

Points clés :

- Handshake Bluetooth + Wi-Fi **nettement plus rapide** que dans les logs du bug initial : `WifiConnectStatus` reçu en **511 ms**, contre 10-12 secondes dans les logs qui montraient le stall (voir `../20260820-analyse-probleme.md`).
- `USB Manager: Switched to accessory gadget`, `Opening USB accessory device` et `Starting to proxy data between HU and MD` apparaissent **à la même milliseconde** (`09:44:00.021`), comme sur les deux tests précédents (`20260820-fix-usb` et `20260820-fix-main`+fix USB non commité) — le fix `usb_accessory_ready` continue de synchroniser correctement les deux runtimes.
- Le DHU est lancé **après coup**, sur une session déjà établie côté téléphone (BT + Wi-Fi + gadget USB déjà en place). L'énumération USB côté kernel (`dwc2`, `new device`, `new address`, `USB_STATE=CONFIGURED`) se déroule normalement dans la demi-seconde qui suit.
- **Aucune erreur `unexpected transfer stall`** sur toute la durée de la session (~20 secondes, jusqu'à l'arrêt volontaire), alors que dans les logs du bug initial elle apparaissait systématiquement et exactement à 10 secondes.
- L'arrêt par `Ctrl+C` est **propre** : `signal exit: initiating clean disconnect` → `exiting process after teardown`, sans blocage ni relance intempestive. Ceci confirme au passage que le fix `d3a35e81` / `c89fed4b` (prévention de la race de reconnexion au shutdown signalé) fonctionne toujours correctement en présence du nouveau fix USB.

## 2. Point secondaire, sans rapport avec le bug corrigé

Les tentatives de pont "companion app" échouent en boucle, retentées toutes les ~10 secondes :

```text
09:43:57.965  proxy: tcp_bridge[HTTP]: failed to connect to remote server 10.0.0.5:9999: Connection refused (os error 111)
09:43:57.966  proxy: tcp_bridge[WS]:   failed to connect to remote server 10.0.0.5:9998: Connection refused (os error 111)
09:44:07.312  proxy: tcp_bridge[HTTP]: failed to connect to remote server 10.0.0.5:9999: Connection refused (os error 111)
09:44:17.360  proxy: tcp_bridge[HTTP]: failed to connect to remote server 10.0.0.5:9999: Connection refused (os error 111)
```

Le téléphone n'a probablement pas d'application companion à l'écoute sur ces ports (9999/9998). Ce canal est indépendant du flux Android Auto principal (déjà noté comme non déterminant dans l'analyse initiale) et n'a aucun impact sur la stabilité de la session AA observée ici.

## 3. Conclusion

Ce test confirme le fix `usb_accessory_ready` dans un **ordre de démarrage différent** des tests précédents (téléphone connecté avant le DHU, plutôt que tête d'unité déjà présente) :

- Synchronisation switch USB / ouverture device toujours instantanée.
- Aucun stall à 10 secondes.
- Arrêt propre au signal, sans régression sur le fix de shutdown précédent.

Le correctif semble donc robuste indépendamment de l'ordre exact des événements de connexion, ce qui renforce la confiance dans le diagnostic initial (race condition pure, résolue par la synchronisation explicite) plutôt qu'un simple effet de timing favorable.

**Reste à faire pour validation complète :** un test sur la tête d'unité Volvo réelle (celle où le bug a été capturé à l'origine), et idéalement une session de plus longue durée pour écarter tout stall tardif.
