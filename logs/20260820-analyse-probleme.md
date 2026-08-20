# Analyse : échec récurrent de connexion Android Auto au démarrage

## Contexte

Log analysé : `20260820080916_aa-proxy-rs_logs/aa-proxy-rs.log`
Device : Raspberry Pi 4, `aa-proxy-rs` build `20260810_074609`, git `6715391`
Téléphone : Pixel 9 (`C0:1C:6A:6C:1E:5A`), mode `bt_wireless_proxy_mode = car-wifi-mitm`

Symptôme rapporté : au démarrage du véhicule, le téléphone n'arrive pas à établir une session Android Auto avec la tête d'unité (autoradio).

## 1. Constat à partir des logs

Le cycle suivant se répète **7 à 8 fois** sur les 2 premières minutes 30 du log, sans jamais aboutir à une session stable :

```text
00:00:19.726  bluetooth: stage #5 of 5: Received WifiConnectStatus frame from phone (⏱️ 12720 ms)
00:00:19.726  proxy:     MD TCP server: listening for phone connection...
00:00:20.044  proxy:     TCP server: new client connected: 10.0.0.5:42316
00:00:20.058  proxy:     bt-wireless-proxy car-wifi-mitm: PHONE TCP accepted on MD listener; commit barrier seq=1
00:00:20.058  proxy:     📂 Opening USB accessory device: /dev/usb_accessory
00:00:20.059  proxy:     ♾️ Starting to proxy data between HU and MD...
00:00:20.059  mitm/HU:   🔄 running in passthrough mode (MITM disabled in config)
00:00:20.059  mitm/MD:   🔄 running in passthrough mode (MITM disabled in config)
00:00:22.351  usb:       🔌 USB Manager: Switched to accessory gadget      <-- 2.3 s APRÈS le début du proxying
00:00:30.068  ERROR proxy: 🔴 Connection error: unexpected transfer stall
00:00:30.068  proxy:     disassociating WiFi client: DE:E9:3B:55:97:CF
00:00:30.071  proxy:     ⌛ session time: 10s 11ms 954us 49ns
00:00:30.071  proxy:     💤 waiting for bluetooth handshake...
00:00:30.071  main:      📵 TCP/USB connection closed or not started, trying again...
```

Points clés observés :

- Le handshake Bluetooth + Wi-Fi avec le téléphone **réussit à chaque fois** (les 5 étapes `stage #1` à `stage #5` s'exécutent normalement, la connexion TCP côté téléphone (MD) est acceptée).
- `aa-proxy-rs` ouvre `/dev/usb_accessory` et démarre le proxying (`Starting to proxy data between HU and MD`) **avant** que le message `USB Manager: Switched to accessory gadget` n'apparaisse — écart observé : **~2,3 secondes** à chaque cycle (ex. `20.059` → `22.351`, `37.190` → `39.120`, `56.801` → `59.096`, etc., constant sur tout le log).
- Exactement **10 secondes** après l'ouverture de la session (`session time: 10s ...` à chaque occurrence, variance de quelques millisecondes), l'erreur `🔴 Connection error: unexpected transfer stall` est levée et la session est coupée (`disassociating WiFi client`).
- Le cycle recommence ensuite depuis zéro (nouvelle tentative Bluetooth), sans jamais franchir ce cap des 10 secondes.
- Erreurs secondaires observées en marge, non déterminantes pour le symptôme principal :
  - `bluetooth AA handshake error: Software caused connection abort (os error 103)` — abandon ponctuel du handshake BT, propre aux reconnexions répétées.
  - `WARN Headset Profile (HSP) registering error: Bluetooth operation not permitted: UUID already registered, ignoring` — ré-enregistrement d'un profil déjà actif, sans conséquence fonctionnelle.
  - `ERROR media_dump_base_port is set but mitm = false — media tap disabled!` — avertissement de configuration cosmétique (fonctionnalité de capture média désactivée), **sans rapport** avec l'échec de connexion.
  - Les échecs `tcp_bridge[HTTP]/[WS]/[SWUPDATE]: Connection refused` sur les ports 9999/9998/9997 concernent le pont "companion app" (application compagnon sur le téléphone), un canal secondaire indépendant du flux Android Auto principal.

## 2. Cause racine

Le code fait tourner **deux tâches asynchrones indépendantes, sur deux runtimes Tokio distincts, sans aucune synchronisation entre elles** :

- `tokio_main` (runtime multi-thread classique) pilote le **switch du gadget USB** en mode "accessory" via `UsbGadgetState::enable_default_and_wait_for_accessory` (`src/usb_gadget.rs`). Cette opération est asynchrone et prend, selon les logs, environ **2 à 3 secondes** avant de logguer `Switched to accessory gadget`.
- `io_loop` (runtime `tokio_uring` séparé) pilote le **proxying des données**. Dès que le téléphone se connecte en TCP, il ouvre immédiatement `/dev/usb_accessory` (`src/proxy.rs`) et démarre le transfert de données, **sans attendre** que le switch du gadget USB soit effectivement terminé côté `tokio_main`.

Conséquence : à chaque session, `io_loop` ouvre le device USB et commence à proxyer **avant** que la tête d'unité (HU) ne voie réellement le Raspberry Pi comme un accessoire Android Auto sur le bus USB. Pendant cette fenêtre (les 2-3 premières secondes, mais en réalité toute la fenêtre de 10 secondes puisque le lien HU reste inutilisable), **aucun octet ne peut être échangé côté HU**.

Le détecteur de "stall" de `aa-proxy-rs` (`src/proxy.rs`, timeout fixe = `config.timeout_secs`, valeur par défaut **10 secondes**) constate qu'aucune donnée n'a transité pendant cette fenêtre et lève systématiquement l'erreur `unexpected transfer stall`, ce qui tue la session et relance tout le cycle (Bluetooth → Wi-Fi → TCP → USB) depuis le début — sans jamais laisser le temps au switch USB de se stabiliser avant l'expiration du timeout.

**Il ne s'agit pas d'un problème côté téléphone, ni d'un problème de configuration** : c'est une course (race condition) entre deux tâches internes à `aa-proxy-rs` qui ne se synchronisent pas.

### Localisation dans le code (avant correctif)

| Élément | Fichier | Rôle |
|---|---|---|
| Ouverture de `/dev/usb_accessory` + début du proxying | `src/proxy.rs` (`io_loop`) | Démarre sans attendre la fin du switch USB |
| Switch réel du gadget USB en mode accessory | `src/usb_gadget.rs` (`enable_default_and_wait_for_accessory`), appelé depuis `src/main.rs` (`enable_usb_if_present`) | Tourne sur un runtime séparé, ~2-3 s, sans notifier `io_loop` |
| Détecteur de stall (timeout 10 s) | `src/proxy.rs` (boucle `io_loop`) | Tue la session si 0 octet transféré pendant `config.timeout_secs` |

## 3. Stratégie de correction

Introduire un signal de synchronisation explicite entre les deux tâches, sur le modèle de ce qui existe déjà dans le code pour d'autres besoins similaires (`tcp_start: Arc<Notify>`, `usb_connected: Arc<AtomicBool>`, déjà partagés avec succès entre `tokio_main` et `io_loop` à travers la frontière des deux runtimes) :

1. Créer un nouveau `Arc<tokio::sync::Notify>` (`usb_accessory_ready`), partagé entre `tokio_main` et `io_loop`.
2. Dans `tokio_main`, notifier ce signal (`notify_one()`) juste après que `enable_usb_if_present(...)` a confirmé le switch du gadget USB — pour les deux ordres de configuration possibles (`change_usb_order` vrai ou faux).
3. Dans `io_loop`, **avant** d'ouvrir `/dev/usb_accessory`, attendre ce signal, avec un **délai maximum borné** (8 secondes, choisi volontairement **sous** le timeout de stall de 10 secondes) :
   - Si le signal arrive avant : on ouvre le device immédiatement après, comme prévu.
   - Si le délai expire (cas anormal — switch USB en échec, absence de hardware gadget, etc.) : on logue un avertissement et on ouvre quand même le device, pour ne jamais bloquer indéfiniment le proxy et préserver le comportement actuel en dernier recours.

Propriétés recherchées :
- **Pas de deadlock** : `Notify::notify_one()` mémorise un "permit" si le switch se termine avant que `io_loop` ne soit en attente (ex. cas `change_usb_order = true`, où le switch a lieu avant même le handshake) — l'attente est alors instantanée.
- **Pas de régression** si le hardware USB gadget n'est pas présent (`usb = None` côté `tokio_main`) : `enable_usb_if_present` retourne immédiatement `true` dans ce cas, donc le signal est émis sans délai.
- **Pas de blocage permanent** : le timeout de 8 s garantit qu'un problème indépendant (échec du switch gadget) ne fait pas attendre `io_loop` plus longtemps que la marge disponible avant le timeout de stall.
- Le chemin `dhu` / `bt_car_wifi_mitm_hu_tcp` (qui n'ouvre pas `/dev/usb_accessory`, mais utilise un listener TCP DHU) n'est pas concerné par cette attente.

## 4. Correction appliquée

### `src/main.rs`

- Création du signal partagé, aux côtés des primitives existantes (`usb_connected`, `tcp_start`) :

```rust
let usb_connected = Arc::new(AtomicBool::new(false));
let usb_connected_cloned = usb_connected.clone();
let usb_accessory_ready = Arc::new(Notify::new());
let usb_accessory_ready_cloned = usb_accessory_ready.clone();
```

- Ajout du paramètre à la signature de `tokio_main` :

```rust
async fn tokio_main(
    // ...
    profile_connected: Arc<AtomicBool>,
    usb_connected: Arc<AtomicBool>,
    usb_accessory_ready: Arc<Notify>,
    ws_event_tx: broadcast::Sender<ServerEvent>,
    // ...
) -> Result<()> {
```

- Notification après chaque switch USB réussi, dans les deux branches (`change_usb_order` vrai et faux) :

```rust
if cfg.change_usb_order {
    if !enable_usb_if_present(
        &mut usb,
        accessory_started.clone(),
        cfg.usb_gadget_require_accessory_start,
    )
    .await
    {
        tokio::time::sleep(std::time::Duration::from_millis(500)).await;
        continue;
    }
    usb_accessory_ready.notify_one();
}
```

```rust
if !cfg.change_usb_order {
    if !enable_usb_if_present(
        &mut usb,
        accessory_started.clone(),
        cfg.usb_gadget_require_accessory_start,
    )
    .await
    {
        tokio::time::sleep(std::time::Duration::from_millis(500)).await;
        continue;
    }
    usb_accessory_ready.notify_one();
}
```

- Transmission du signal aux deux tâches (`runtime.spawn(tokio_main(...))` et `run_io_loop!(io_loop(...))`).

### `src/proxy.rs`

- Nouvelle constante, bornée sous le timeout de stall par défaut :

```rust
const USB_ACCESSORY_PATH: &str = "/dev/usb_accessory";
// Bornée sous le timeout de transfer-stall (config.timeout_secs, 10 s par défaut) pour
// qu'une notification manquée ne dépasse jamais le détecteur de stall, et au-dessus de
// la durée observée du switch gadget (~2-3 s) pour ne jamais attendre inutilement.
const USB_ACCESSORY_READY_TIMEOUT: Duration = Duration::from_secs(8);
```

- Ajout du paramètre à `io_loop` :

```rust
pub async fn io_loop(
    // ...
    usb_connected: Arc<AtomicBool>,
    usb_accessory_ready: Arc<Notify>,
    script_registry: Option<Arc<ScriptRegistry>>,
    // ...
) -> Result<()> {
```

- Attente bornée avant l'ouverture du device USB :

```rust
} else {
    // Le switch du gadget USB en mode accessory (tokio_main / usb_gadget.rs) tourne en
    // parallèle sur un autre runtime et peut prendre quelques secondes. Ouvrir le device
    // accessory avant la fin de ce switch signifie qu'aucun octet n'atteint jamais le
    // vrai contrôleur USB (UDC), ce qui déclenche le détecteur de stall ci-dessus à
    // chaque session. On attend d'abord le signal "switché", borné pour qu'un switch
    // en échec ou sauté ailleurs ne puisse pas bloquer cette boucle indéfiniment.
    if timeout(
        USB_ACCESSORY_READY_TIMEOUT,
        usb_accessory_ready.notified(),
    )
    .await
    .is_err()
    {
        warn!(
            "{} ⏳ Timed out waiting for USB gadget accessory-switch signal; opening anyway",
            NAME
        );
    }

    info!(
        "{} 📂 Opening USB accessory device: <u>{}</u>",
        NAME, USB_ACCESSORY_PATH
    );
    match OpenOptions::new()
        .read(true)
        .write(true)
        .create(false)
        .open(USB_ACCESSORY_PATH)
        .await
    {
        Ok(s) => hu_usb = Some(s),
        Err(e) => {
            error!("{} 🔴 Error opening USB accessory: {}", NAME, e);
            let _ = need_restart.send(None);
            continue;
        }
    }
}
```

## 5. Validation attendue

Après correctif, sur le terrain, le log devrait montrer :

- `USB Manager: Switched to accessory gadget` avant (ou immédiatement avant) `Opening USB accessory device` / `Starting to proxy data between HU and MD`, au lieu d'après.
- Plus d'erreur `unexpected transfer stall` à la 10ᵉ seconde de chaque session.
- Établissement de la session Android Auto dès la première tentative de connexion du téléphone, sans boucle de reconnexion Bluetooth/Wi-Fi répétée.

Si le problème persiste malgré le correctif, il faudra examiner si le switch du gadget USB lui-même échoue ou prend plus de 8 secondes (auquel cas le timeout `USB_ACCESSORY_READY_TIMEOUT` devra être réévalué), ou si la tête d'unité elle-même ne négocie pas correctement le protocole AOA (Android Open Accessory) une fois le gadget switché.

## Annexe : élimination des autres causes possibles (matériel, câble, voiture, téléphone)

Avant de conclure à un bug logiciel interne à `aa-proxy-rs`, il est légitime de se demander si le symptôme pourrait venir du Raspberry Pi/buildroot, du câble de connexion, de la voiture, ou du téléphone. Voici ce que dit le log pour chacune de ces hypothèses.

### Téléphone → écarté

Sur les 7-8 tentatives du log, le Pixel 9 réussit **à chaque fois** l'intégralité du handshake Bluetooth + Wi-Fi (les 5 étapes, de `WifiStartRequest` à `WifiConnectStatus`) et se connecte en TCP au moment attendu. Le téléphone fait tout correctement, systématiquement, sur toutes les tentatives. Rien dans son comportement ne varie ou n'échoue.

### Voiture / tête d'unité (HU) → très improbable

L'autoradio n'a même pas l'occasion d'agir : c'est le Raspberry Pi lui-même qui ouvre `/dev/usb_accessory` et qui pilote le switch du gadget USB en interne (`enable_default_and_wait_for_accessory`). La tête d'unité est un acteur passif — elle attend juste que le RPi lui présente un device USB valide. Le problème se situe entièrement côté logiciel RPi, avant même que la voiture n'ait quoi que ce soit à faire.

### Câble → improbable, mais pas vérifiable à 100 % avec ce seul log

Un câble défectueux donne typiquement des symptômes irréguliers : déconnexions USB aléatoires, erreurs de renégociation, timings variables, messages kernel de type "USB disconnect"/"USB reset" dans `dmesg`. Ici au contraire, le pattern est **parfaitement régulier** :

- écart constant de ~2,3 s entre `Opening USB accessory device` et `Switched to accessory gadget` à chaque cycle,
- stall systématiquement à **10 secondes pile** (`10s 11ms`, `10s 7ms`, `10s 9ms`, `10s 8ms`, `10s 13ms`...) — cette régularité correspond exactement au timeout logiciel configuré (`config.timeout_secs = 10`), pas à un comportement physique aléatoire.

`aa-proxy-rs.log` est un log applicatif, pas le log kernel (`dmesg`) : il n'offre donc pas de visibilité totale sur la couche physique USB. Mais la régularité observée s'explique entièrement par le timing logiciel, sans avoir besoin d'invoquer un câble marginal.

### Raspberry Pi / buildroot (matériel et OS) → écarté

Le RPi fonctionne correctement : le switch de gadget USB se termine **avec succès** à chaque cycle, juste ~2,3 s trop tard par rapport au moment où le proxy commence à l'utiliser. Ce n'est pas une panne matérielle ni un bug du buildroot — c'est un défaut d'ordonnancement entre deux tâches internes du binaire `aa-proxy-rs` (deux runtimes Tokio qui ne s'attendent pas l'un l'autre), décrit en section 2.

### Test décisif

Le test qui permettra de confirmer définitivement le diagnostic : après build et déploiement du correctif, avec **le même câble, la même voiture et le même téléphone**, si le stall à 10 s disparaît et que la session Android Auto s'établit dès la première tentative, cela confirme que la cause était bien ce bug logiciel. Si le problème persiste malgré le correctif, ce sera le signal qu'il faut alors regarder ailleurs : `dmesg` pour un souci de câble/contrôleur USB (UDC) physique, ou un souci propre à la négociation AOA de cet autoradio en particulier.
