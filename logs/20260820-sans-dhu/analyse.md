# Analyse : test sans DHU (aucun consommateur côté USB accessory)

## Contexte

Log analysé : `20260820-sans-dhu.log`
Build : `aa-proxy-rs` `20260820_090313`, git `f338e53-br#90dfa96`
Branche : `fix/usb-accessory-race` (fix `tokio_main` + fix `usb_accessory_ready`, tous deux appliqués)
Téléphone : Pixel 9 (`C0:1C:6A:6C:1E:5A`), mode `car-wifi-mitm`
Scénario de test : `aa-proxy-rs` est lancé, le téléphone se connecte, **mais le DHU n'est jamais lancé** côté PC — rien ne lit/écrit réellement sur `/dev/usb_accessory` côté hôte.
Symptôme rapporté (côté téléphone) : l'écran affiche des débuts de connexion Android Auto qui se relancent toutes les X secondes.

## 1. Constat : le stall à 10s revient, mais ce n'est pas une régression

Trois cycles complets s'enchaînent dans ce log, tous identiques dans leur structure :

```text
09:55:17.683  proxy: 🧪 PHONE TCP accepted on MD listener; commit barrier seq=1
09:55:20.489  usb:   🔌 USB Manager: Switched to accessory gadget
09:55:20.489  proxy: 📂 Opening USB accessory device: /dev/usb_accessory
09:55:20.489  proxy: ♾️ Starting to proxy data between HU and MD...
[2857.618]    dwc2: new device is high-speed
[2857.722]    android_work: sent uevent USB_STATE=CONNECTED
[2857.895]    dwc2: new address 51
[2857.913]    android_work: sent uevent USB_STATE=CONFIGURED
              ... (10s plus tard) ...
09:55:22.275  ERROR proxy: 🔴 Connection error: unexpected transfer stall
09:55:22.276  proxy: ⌛ session time: 10s 5ms 249us 49ns
09:55:22.276  main:  📵 TCP/USB connection closed or not started, trying again...
```

(Idem seq=2 : proxy démarré à `09:55:44.062`, stall à `09:55:54.066`, "session time: 10s 4ms". Idem seq=3 : proxy démarré à `09:55:59.889`, coupé par `Ctrl+C` à `09:56:01.668` avant le stall suivant.)

Points importants :

- **Le fix `usb_accessory_ready` fonctionne toujours parfaitement** : sur les 3 cycles, `Switched to accessory gadget`, `Opening USB accessory device` et `Starting to proxy data` sont systématiquement à la même milliseconde. Aucune régression du fix.
- **L'énumération USB kernel réussit quand même** (`new device`, `USB_STATE=CONFIGURED`) — c'est normal : l'énumération électrique/USB de bas niveau se fait automatiquement dès qu'un câble est branché côté hôte, indépendamment du fait qu'une application y lise ou écrive des données.
- Mais **aucune application ne consomme le flux Android Auto côté USB** (pas de DHU lancé, pas de vraie tête d'unité). Le détecteur de stall (`config.timeout_secs`, 10s par défaut) surveille l'absence d'octets **applicatifs** échangés — et comme personne ne parle le protocole AA de l'autre côté, il n'y a logiquement aucun octet, donc le stall se déclenche **à 10s pile, comme prévu par la configuration**.

**Conclusion sur ce point : ce n'est pas un bug.** C'est le comportement attendu quand rien ne consomme réellement l'accessoire USB — le proxy ne peut pas deviner qu'il doit attendre indéfiniment, et 10s est le délai configuré avant d'abandonner et de relancer un cycle complet. Ce test confirme au contraire que le diagnostic initial était le bon : la race concernait uniquement la synchronisation entre le switch du gadget et l'ouverture du device (résolue), pas le fonctionnement du détecteur de stall lui-même (qui est correct et se comporte comme conçu en l'absence de tête d'unité).

C'est cohérent avec ce que tu observes côté téléphone : "l'écran affiche des débuts de connexion qui se relancent toutes les X secondes" — c'est exactement le cycle BT → Wi-Fi → TCP → USB → stall (~10s) → reconnexion qui tourne en boucle, faute d'un DHU ou d'une tête d'unité réelle pour terminer la session.

## 2. Points secondaires observés

- `bluetooth AA handshake error: Software caused connection abort (os error 103)` (une fois, ligne 114) : abandon ponctuel du handshake BT pendant une reconnexion rapide — déjà noté comme non déterminant dans l'analyse initiale.
- `Headset Profile (HSP) registering error: UUID already registered, ignoring` (à chaque cycle) : ré-enregistrement d'un profil déjà actif suite à la reconnexion rapide, sans conséquence fonctionnelle.
- `br-connection-busy` (quelques occurrences) : adaptateur Bluetooth temporairement occupé pendant les tentatives de reconnexion rapprochées, se résout de lui-même en moins d'une seconde.
- `tcp_bridge[HTTP/WS/SWUPDATE]: Connection reset by peer` / `Connection refused` : canal companion app, indépendant du flux Android Auto principal.

Aucun de ces points n'est lié au fix USB ni à un nouveau problème.

## 3. Conclusion

Ce test ne révèle pas de régression : il montre que **sans consommateur applicatif du flux USB (DHU ou vraie tête d'unité), le proxy relance un cycle toutes les ~10s, par conception**. C'est attendu et distinct du bug corrigé (qui provoquait le stall même en présence d'une vraie tête d'unité, à cause d'une race de timing interne).

Pour valider complètement le fix sur le terrain, il faut un test avec un consommateur USB réellement actif : soit le DHU lancé (comme dans `../20260820-fix-usb/` et `../20260820-test-demarrage/`, où la session tient sans stall), soit la tête d'unité Volvo réelle.
