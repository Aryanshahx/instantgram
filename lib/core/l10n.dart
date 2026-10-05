import 'package:flutter/widgets.dart';

import '../services/app_prefs.dart';

/// A language the app can show its menus in.
class AppLanguage {
  const AppLanguage(this.code, this.name, this.english);
  final String code;

  /// The language's own name.
  final String name;
  final String english;
}

const List<AppLanguage> kLanguages = [
  AppLanguage('en', 'English', 'English'),
  AppLanguage('hi', 'हिन्दी', 'Hindi'),
  AppLanguage('es', 'Español', 'Spanish'),
  AppLanguage('fr', 'Français', 'French'),
];

/// The chosen language. The words are the English text itself (`context.tr('Settings')`), so
/// a text that has no translation yet simply stays in English.
class Language extends ValueNotifier<String> {
  Language._() : super('en');
  static final Language instance = Language._();

  /// Reads the saved choice (call once at start).
  void load() => value = _valid(AppPrefs.instance.language);

  void choose(String code) {
    final c = _valid(code);
    AppPrefs.instance.language = c;
    value = c;
  }

  static String _valid(String code) =>
      kLanguages.any((l) => l.code == code) ? code : 'en';

  String translate(String english) {
    if (value == 'en') return english;
    return _words[value]?[english] ?? english;
  }
}

/// Wraps the app so every widget that called `context.tr` is rebuilt when the language changes.
class LanguageScope extends InheritedNotifier<Language> {
  const LanguageScope({super.key, required Language language, required super.child})
    : super(notifier: language);
}

extension TrContext on BuildContext {
  /// [english] in the chosen language.
  String tr(String english) {
    final scope = dependOnInheritedWidgetOfExactType<LanguageScope>();
    return (scope?.notifier ?? Language.instance).translate(english);
  }
}

const Map<String, Map<String, String>> _words = {
  'hi': {
    'Discover': 'डिस्कवर',
    'Explore': 'एक्सप्लोर',
    'Clips': 'क्लिप्स',
    'Chats': 'चैट',
    'Me': 'मैं',
    'Post': 'पोस्ट',
    'Posts': 'पोस्ट',
    'Followers': 'फ़ॉलोअर्स',
    'Following': 'फ़ॉलो कर रहे हैं',
    'Edit profile': 'प्रोफ़ाइल बदलें',
    'Share profile': 'प्रोफ़ाइल शेयर करें',
    'Settings': 'सेटिंग्स',
    'Search settings': 'सेटिंग्स खोजें',
    'Add account': 'खाता जोड़ें',
    'History': 'इतिहास',
    'Manage time': 'समय प्रबंधन',
    'Account privacy': 'खाता गोपनीयता',
    'Blocked': 'ब्लॉक किए गए',
    'Accessibility': 'सुलभता',
    'Language': 'भाषा',
    'About': 'जानकारी',
    'Privacy policy': 'गोपनीयता नीति',
    'Terms of use': 'उपयोग की शर्तें',
    'App update': 'ऐप अपडेट',
    'Log out': 'लॉग आउट',
    'Account': 'खाता',
    'Your activity': 'आपकी गतिविधि',
    'Help and about': 'मदद और जानकारी',
    'Create account': 'खाता बनाएँ',
    'Full name': 'पूरा नाम',
    'Username': 'यूज़रनेम',
    'Email': 'ईमेल',
    'Password': 'पासवर्ड',
    'Date of birth': 'जन्म तिथि',
    'Choose your date of birth': 'अपनी जन्म तिथि चुनें',
    'Choose your language': 'अपनी भाषा चुनें',
    'You must be at least 13 years old.': 'आपकी उम्र कम से कम 13 साल होनी चाहिए।',
    'Private account': 'निजी खाता',
    'Only people you approve can see your posts and clips.':
        'केवल वे लोग जिन्हें आप मंज़ूर करें आपके पोस्ट और क्लिप देख सकते हैं।',
    'Follow requests': 'फ़ॉलो अनुरोध',
    'Accept': 'स्वीकारें',
    'Decline': 'अस्वीकारें',
    'Unblock': 'अनब्लॉक',
    'Block': 'ब्लॉक करें',
    'Nobody is blocked.': 'किसी को ब्लॉक नहीं किया गया है।',
    'Clear history': 'इतिहास साफ़ करें',
    'Nothing here yet.': 'यहाँ अभी कुछ नहीं है।',
    'Daily limit': 'रोज़ की सीमा',
    'Today': 'आज',
    'Off': 'बंद',
    'Text size': 'अक्षर का आकार',
    'Bold text': 'गाढ़े अक्षर',
    'Reduce motion': 'कम एनिमेशन',
    'Check for updates': 'अपडेट जांचें',
    'Switch account': 'खाता बदलें',
    'Cancel': 'रद्द करें',
    'Share': 'शेयर',
    'Next': 'आगे',
    'Audience': 'दर्शक',
    'Everyone': 'सब लोग',
    'Followers only': 'सिर्फ़ फ़ॉलोअर्स',
    'Only me': 'सिर्फ़ मैं',
    'Also share to your story': 'अपनी स्टोरी में भी शेयर करें',
    'Hide like count': 'लाइक की गिनती छुपाएँ',
    'Hide comment count': 'कमेंट की गिनती छुपाएँ',
    'Hide share count': 'शेयर की गिनती छुपाएँ',
    'Report': 'रिपोर्ट',
    'Send': 'भेजें',
  },
  'es': {
    'Discover': 'Descubrir',
    'Explore': 'Explorar',
    'Clips': 'Clips',
    'Chats': 'Chats',
    'Me': 'Yo',
    'Post': 'Publicación',
    'Posts': 'Publicaciones',
    'Followers': 'Seguidores',
    'Following': 'Siguiendo',
    'Edit profile': 'Editar perfil',
    'Share profile': 'Compartir perfil',
    'Settings': 'Ajustes',
    'Search settings': 'Buscar ajustes',
    'Add account': 'Añadir cuenta',
    'History': 'Historial',
    'Manage time': 'Gestionar tiempo',
    'Account privacy': 'Privacidad de la cuenta',
    'Blocked': 'Bloqueados',
    'Accessibility': 'Accesibilidad',
    'Language': 'Idioma',
    'About': 'Acerca de',
    'Privacy policy': 'Política de privacidad',
    'Terms of use': 'Términos de uso',
    'App update': 'Actualización de la app',
    'Log out': 'Cerrar sesión',
    'Account': 'Cuenta',
    'Your activity': 'Tu actividad',
    'Help and about': 'Ayuda e información',
    'Create account': 'Crear cuenta',
    'Full name': 'Nombre completo',
    'Username': 'Nombre de usuario',
    'Email': 'Correo',
    'Password': 'Contraseña',
    'Date of birth': 'Fecha de nacimiento',
    'Choose your date of birth': 'Elige tu fecha de nacimiento',
    'Choose your language': 'Elige tu idioma',
    'You must be at least 13 years old.': 'Debes tener al menos 13 años.',
    'Private account': 'Cuenta privada',
    'Only people you approve can see your posts and clips.':
        'Solo las personas que apruebes pueden ver tus publicaciones y clips.',
    'Follow requests': 'Solicitudes de seguimiento',
    'Accept': 'Aceptar',
    'Decline': 'Rechazar',
    'Unblock': 'Desbloquear',
    'Block': 'Bloquear',
    'Nobody is blocked.': 'No has bloqueado a nadie.',
    'Clear history': 'Borrar historial',
    'Nothing here yet.': 'Aún no hay nada aquí.',
    'Daily limit': 'Límite diario',
    'Today': 'Hoy',
    'Off': 'Desactivado',
    'Text size': 'Tamaño del texto',
    'Bold text': 'Texto en negrita',
    'Reduce motion': 'Reducir movimiento',
    'Check for updates': 'Buscar actualizaciones',
    'Switch account': 'Cambiar de cuenta',
    'Cancel': 'Cancelar',
    'Share': 'Compartir',
    'Next': 'Siguiente',
    'Audience': 'Audiencia',
    'Everyone': 'Todos',
    'Followers only': 'Solo seguidores',
    'Only me': 'Solo yo',
    'Also share to your story': 'Compartir también en tu historia',
    'Hide like count': 'Ocultar recuento de Me gusta',
    'Hide comment count': 'Ocultar recuento de comentarios',
    'Hide share count': 'Ocultar recuento de compartidos',
    'Report': 'Denunciar',
    'Send': 'Enviar',
  },
  'fr': {
    'Discover': 'Découvrir',
    'Explore': 'Explorer',
    'Clips': 'Clips',
    'Chats': 'Discussions',
    'Me': 'Moi',
    'Post': 'Publication',
    'Posts': 'Publications',
    'Followers': 'Abonnés',
    'Following': 'Abonnements',
    'Edit profile': 'Modifier le profil',
    'Share profile': 'Partager le profil',
    'Settings': 'Paramètres',
    'Search settings': 'Rechercher un paramètre',
    'Add account': 'Ajouter un compte',
    'History': 'Historique',
    'Manage time': 'Gérer le temps',
    'Account privacy': 'Confidentialité du compte',
    'Blocked': 'Bloqués',
    'Accessibility': 'Accessibilité',
    'Language': 'Langue',
    'About': 'À propos',
    'Privacy policy': 'Politique de confidentialité',
    'Terms of use': "Conditions d'utilisation",
    'App update': "Mise à jour de l'app",
    'Log out': 'Se déconnecter',
    'Account': 'Compte',
    'Your activity': 'Votre activité',
    'Help and about': 'Aide et infos',
    'Create account': 'Créer un compte',
    'Full name': 'Nom complet',
    'Username': "Nom d'utilisateur",
    'Email': 'E-mail',
    'Password': 'Mot de passe',
    'Date of birth': 'Date de naissance',
    'Choose your date of birth': 'Choisissez votre date de naissance',
    'Choose your language': 'Choisissez votre langue',
    'You must be at least 13 years old.': 'Vous devez avoir au moins 13 ans.',
    'Private account': 'Compte privé',
    'Only people you approve can see your posts and clips.':
        'Seules les personnes que vous approuvez voient vos publications et clips.',
    'Follow requests': "Demandes d'abonnement",
    'Accept': 'Accepter',
    'Decline': 'Refuser',
    'Unblock': 'Débloquer',
    'Block': 'Bloquer',
    'Nobody is blocked.': "Vous n'avez bloqué personne.",
    'Clear history': "Effacer l'historique",
    'Nothing here yet.': "Rien ici pour l'instant.",
    'Daily limit': 'Limite quotidienne',
    'Today': "Aujourd'hui",
    'Off': 'Désactivé',
    'Text size': 'Taille du texte',
    'Bold text': 'Texte en gras',
    'Reduce motion': 'Réduire les animations',
    'Check for updates': 'Rechercher des mises à jour',
    'Switch account': 'Changer de compte',
    'Cancel': 'Annuler',
    'Share': 'Partager',
    'Next': 'Suivant',
    'Audience': 'Audience',
    'Everyone': 'Tout le monde',
    'Followers only': 'Abonnés uniquement',
    'Only me': 'Moi uniquement',
    'Also share to your story': 'Partager aussi dans votre story',
    'Hide like count': "Masquer le nombre de J'aime",
    'Hide comment count': 'Masquer le nombre de commentaires',
    'Hide share count': 'Masquer le nombre de partages',
    'Report': 'Signaler',
    'Send': 'Envoyer',
  },
};
