# Grok Notch

Droplet SwiftUI pour discuter avec ses bots Grok Bot depuis la notch de macOS, dans Droppy. Intégration indépendante et expérimentale, non affiliée à Droppy ou à Grok Bot.

## Fonctions

- Équipe et conversations de la session Grok Bot locale, avatars et derniers messages.
- Un clic sur un bot ouvre directement sa conversation dans la notch.
- Envoi de messages réels, historique et brouillons en mémoire par conversation.
- Aperçus cliquables dans le HUD de Droppy, file de notifications et Live Activities.
- Bouton séparé pour ouvrir Grok Bot. Les approbations restent dans cette application.

## Compatibilité

Le code ne contient aucun compte, identifiant de bot ou chemin de profil propre à son auteur. Chaque installation utilise le compte déjà connecté dans sa propre application Grok Bot. Il ne lit pas un dossier `.grokbot` appartenant à quelqu’un d’autre.

Le bridge a été testé avec **Grok Bot 0.78.1**, **Droppy 16.2.1 nightly**, **DroppyKit 1.20.1**, Node.js 24 et macOS. Il utilise des interfaces internes observées et le diagnostic Electron, pas une API publique officielle. Les fonctions minifiées du générateur d’avatars sont propres à cette version. Une mise à jour de Grok Bot peut casser la connexion ou les avatars. Aucun test sur un second Mac n’a encore été effectué.

Le bundle déclare macOS 14+, Droppy 15.3+ et DroppyKit API 1.16.0 ; ces minimums déclarés ne constituent pas une matrice de compatibilité testée. Compiler nécessite Swift 6.2+ et un Xcode compatible.

## Installation depuis les sources

1. Installer Droppy, Grok Bot dans `/Applications/Grok Bot.app` et Node.js 22 ou supérieur. Connecter son propre compte dans Grok Bot.
2. Cloner ce dépôt. Cloner séparément le SDK, dans un dossier voisin :

   ```sh
   git clone https://gitlab.com/droppyformac1/droppykit.git ../droppykit
   git -C ../droppykit checkout 1.20.1
   ```

3. Depuis ce dépôt, installer le bridge utilisateur :

   ```sh
   python3 Bridge/install.py
   ```

4. Construire avec le script officiel, qui lie le bundle au framework du host :

   ```sh
   ../droppykit/Scripts/droppykit build
   ../droppykit/Scripts/droppykit validate --bundle .build/GrokNotch.droplet --no-submission
   ```

5. Importer `.build/GrokNotch.droplet` dans Droppy → Settings → Store → Local droplets et suivre les demandes du host. Dans les réglages du Droplet, utiliser « Reconnecter » si nécessaire. Cette action peut relancer Grok Bot en activant son diagnostic sur la boucle locale.

Grok Bot doit rester ouvert et connecté. Le bridge démarre à l’ouverture de session via le LaunchAgent utilisateur `local.grok-notch.bridge`. Après une mise à jour ou un lancement normal de Grok Bot, une reconnexion peut être nécessaire.

## Données et sécurité

Ce dépôt contient uniquement les sources, des tests synthétiques et les assets statiques du Droplet. Il ne contient ni conversations, ni avatars de bots personnels, ni captures réelles, ni identifiants de bots réels, ni configuration d’authentification, ni bundle précompilé avec des chemins de compilation.

Le Droplet échange uniquement avec son bridge HTTP sur `127.0.0.1`, sur un port aléatoire. Le secret est généré à chaque démarrage et stocké dans `~/Library/Application Support/Grok Notch Bridge/connection.json`, en mode `0600`. Il n’est pas versionné. Le bridge refuse les requêtes sans secret et les origines web ; le client natif refuse les redirections HTTP. Le serveur n’expose pas de route d’exécution JavaScript arbitraire.

La session et les identifiants restent gérés par Grok Bot. Le Droplet ne copie pas les jetons du compte. Les messages sont envoyés par Grok Bot à son service habituel ; il ne s’agit pas d’un modèle hors ligne. Le code du Droplet n’envoie aucune donnée à GitHub et n’intègre pas de télémétrie.

Le port de diagnostic Electron donne accès à la session de l’application aux processus capables d’y accéder localement. Le secret du bridge ne protège pas ce port de diagnostic distinct. Cette intégration ne doit donc pas être assimilée à une API officielle isolée ou à un produit audité pour la sécurité. Relancer normalement Grok Bot ferme son diagnostic.

Les brouillons, messages et avatars traités par le Droplet restent en mémoire ; les conversations restent également stockées par Grok Bot selon son fonctionnement propre. L’installateur conserve des journaux techniques locaux. Ne jamais joindre de captures, de logs ou de fichiers de profil non vérifiés à une issue publique.

## Notifications

Les alertes sont des aperçus dans la notch via Droppy, pas des notifications du Centre de notifications macOS. Le host arbitre les activités concurrentes. Les messages sont interrogés environ toutes les deux secondes. Les anciens messages ne sont pas rejoués au démarrage ; une réponse affichée peut évoluer sans produire d’alertes répétées. Les réglages permettent de désactiver les aperçus.

## Tests

```sh
Checks/run.sh
python3 Checks/privacy_check.py
```

Les tests du modèle utilisent uniquement des bots et messages synthétiques. Ils couvrent les notifications, les réponses tardives, les brouillons, les erreurs d’envoi sans nouvelle tentative automatique, la pagination et l’arrêt du Droplet.

Le harness peut afficher les conversations réelles de la session locale :

```sh
../droppykit/Scripts/droppykit run -- --shots ./shots --report ./shots/report.json
```

Le dossier `shots/` est ignoré par Git. Ne pas publier ses images sans les vérifier. L’option de développement `--preview-message` affiche un aperçu d’un message déjà chargé, sans envoyer de message.

## Désinstallation

```sh
launchctl bootout gui/$(id -u)/local.grok-notch.bridge
```

Retirer le Droplet dans Droppy et supprimer, si souhaité, `~/Library/LaunchAgents/local.grok-notch.bridge.plist` et `~/Library/Application Support/Grok Notch Bridge/`. Relancer normalement Grok Bot pour fermer le diagnostic.

Les noms et logos des applications restent ceux de leurs détenteurs respectifs. Ce dépôt n’est pas une publication au Droplet Store.
