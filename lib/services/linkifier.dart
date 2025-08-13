import 'package:chan/util.dart';
import 'package:linkify/linkify.dart';

final _looseUrlRegex = RegExp(
  r"(https?:\/\/)?([-a-zA-Z0-9@:%_.\+~#=]{1,256}\.[a-z]{2,})(?:\/[-a-zA-Z0-9$@:%_\+.~#?&/=,!;()'\u007F-\u009F\u00A1-\uFFFF]*)?",
  caseSensitive: false,
  dotAll: true,
);

final _looseUrlRegexWithBackslash = RegExp(
  r"(https?:\/\/)?([-a-zA-Z0-9@:%_.\+~#=]{1,256}\.[a-z]{2,})(?:\/[-a-zA-Z0-9$@:%_\+.~#?&/=,!;()'\\\u007F-\u009F\u00A1-\uFFFF]*)?",
  caseSensitive: false,
  dotAll: true,
);

final _protocolIdentifierRegex = RegExp(
  r'^https?:\/\/',
  caseSensitive: false,
);

// Version 2023072500
const _validTlds = {
  'aaa', 'aarp', 'abb', 'abbott', 'abbvie', 'abc', 'able', 'abogado', 'abudhabi', 'ac', 'academy', 'accenture', 'accountant', 'accountants', 'aco', 'actor', 'ad', 'ads', 'adult', 'ae', 'aeg', 'aero', 'aetna', 'af', 'afl', 'africa', 'ag', 'agakhan', 'agency', 'ai', 'aig', 'airbus', 'airforce', 'airtel', 'akdn', 'al', 'alibaba', 'alipay', 'allfinanz', 'allstate', 'ally', 'alsace', 'alstom', 'am', 'amazon', 'americanexpress', 'americanfamily', 'amex', 'amfam', 'amica', 'amsterdam', 'analytics', 'android', 'anquan', 'anz', 'ao', 'aol', 'apartments', 'app', 'apple', 'aq', 'aquarelle', 'ar', 'arab', 'aramco', 'archi', 'army', 'arpa', 'art', 'arte', 'as', 'asda', 'asia', 'associates', 'at', 'athleta', 'attorney', 'au', 'auction', 'audi', 'audible', 'audio', 'auspost', 'author', 'auto', 'autos', 'avianca', 'aw', 'aws', 'ax', 'axa', 'az', 'azure',
  'ba', 'baby', 'baidu', 'banamex', 'bananarepublic', 'band', 'bank', 'bar', 'barcelona', 'barclaycard', 'barclays', 'barefoot', 'bargains', 'baseball', 'basketball', 'bauhaus', 'bayern', 'bb', 'bbc', 'bbt', 'bbva', 'bcg', 'bcn', 'bd', 'be', 'beats', 'beauty', 'beer', 'bentley', 'berlin', 'best', 'bestbuy', 'bet', 'bf', 'bg', 'bh', 'bharti', 'bi', 'bible', 'bid', 'bike', 'bing', 'bingo', 'bio', 'biz', 'bj', 'black', 'blackfriday', 'blockbuster', 'blog', 'bloomberg', 'blue', 'bm', 'bms', 'bmw', 'bn', 'bnpparibas', 'bo', 'boats', 'boehringer', 'bofa', 'bom', 'bond', 'boo', 'book', 'booking', 'bosch', 'bostik', 'boston', 'bot', 'boutique', 'box', 'br', 'bradesco', 'bridgestone', 'broadway', 'broker', 'brother', 'brussels', 'bs', 'bt', 'build', 'builders', 'business', 'buy', 'buzz', 'bv', 'bw', 'by', 'bz', 'bzh',
  'ca', 'cab', 'cafe', 'cal', 'call', 'calvinklein', 'cam', 'camera', 'camp', 'canon', 'capetown', 'capital', 'capitalone', 'car', 'caravan', 'cards', 'care', 'career', 'careers', 'cars', 'casa', 'case', 'cash', 'casino', 'cat', 'catering', 'catholic', 'cba', 'cbn', 'cbre', 'cbs', 'cc', 'cd', 'center', 'ceo', 'cern', 'cf', 'cfa', 'cfd', 'cg', 'ch', 'chanel', 'channel', 'charity', 'chase', 'chat', 'cheap', 'chintai', 'christmas', 'chrome', 'church', 'ci', 'cipriani', 'circle', 'cisco', 'citadel', 'citi', 'citic', 'city', 'cityeats', 'ck', 'cl', 'claims', 'cleaning', 'click', 'clinic', 'clinique', 'clothing', 'cloud', 'club', 'clubmed', 'cm', 'cn', 'co', 'coach', 'codes', 'coffee', 'college', 'cologne', 'com', 'comcast', 'commbank', 'community', 'company', 'compare', 'computer', 'comsec', 'condos', 'construction', 'consulting', 'contact', 'contractors', 'cooking', 'cool', 'coop', 'corsica', 'country', 'coupon', 'coupons', 'courses', 'cpa', 'cr', 'credit', 'creditcard', 'creditunion', 'cricket', 'crown', 'crs', 'cruise', 'cruises', 'cu', 'cuisinella', 'cv', 'cw', 'cx', 'cy', 'cymru', 'cyou', 'cz',
  'dabur', 'dad', 'dance', 'data', 'date', 'dating', 'datsun', 'day', 'dclk', 'dds', 'de', 'deal', 'dealer', 'deals', 'degree', 'delivery', 'dell', 'deloitte', 'delta', 'democrat', 'dental', 'dentist', 'desi', 'design', 'dev', 'dhl', 'diamonds', 'diet', 'digital', 'direct', 'directory', 'discount', 'discover', 'dish', 'diy', 'dj', 'dk', 'dm', 'dnp', 'do', 'docs', 'doctor', 'dog', 'domains', 'dot', 'download', 'drive', 'dtv', 'dubai', 'dunlop', 'dupont', 'durban', 'dvag', 'dvr', 'dz',
  'earth', 'eat', 'ec', 'eco', 'edeka', 'edu', 'education', 'ee', 'eg', 'email', 'emerck', 'energy', 'engineer', 'engineering', 'enterprises', 'epson', 'equipment', 'er', 'ericsson', 'erni', 'es', 'esq', 'estate', 'et', 'etisalat', 'eu', 'eurovision', 'eus', 'events', 'exchange', 'expert', 'exposed', 'express', 'extraspace',
  'fage', 'fail', 'fairwinds', 'faith', 'family', 'fan', 'fans', 'farm', 'farmers', 'fashion', 'fast', 'fedex', 'feedback', 'ferrari', 'ferrero', 'fi', 'fidelity', 'fido', 'film', 'final', 'finance', 'financial', 'fire', 'firestone', 'firmdale', 'fish', 'fishing', 'fit', 'fitness', 'fj', 'fk', 'flickr', 'flights', 'flir', 'florist', 'flowers', 'fly', 'fm', 'fo', 'foo', 'food', 'football', 'ford', 'forex', 'forsale', 'forum', 'foundation', 'fox', 'fr', 'free', 'fresenius', 'frl', 'frogans', 'frontdoor', 'frontier', 'ftr', 'fujitsu', 'fun', 'fund', 'furniture', 'futbol', 'fyi',
  'ga', 'gal', 'gallery', 'gallo', 'gallup', 'game', 'games', 'gap', 'garden', 'gay', 'gb', 'gbiz', 'gd', 'gdn', 'ge', 'gea', 'gent', 'genting', 'george', 'gf', 'gg', 'ggee', 'gh', 'gi', 'gift', 'gifts', 'gives', 'giving', 'gl', 'glass', 'gle', 'global', 'globo', 'gm', 'gmail', 'gmbh', 'gmo', 'gmx', 'gn', 'godaddy', 'gold', 'goldpoint', 'golf', 'goo', 'goodyear', 'goog', 'google', 'gop', 'got', 'gov', 'gp', 'gq', 'gr', 'grainger', 'graphics', 'gratis', 'green', 'gripe', 'grocery', 'group', 'gs', 'gt', 'gu', 'guardian', 'gucci', 'guge', 'guide', 'guitars', 'guru', 'gw', 'gy',
  'hair', 'hamburg', 'hangout', 'haus', 'hbo', 'hdfc', 'hdfcbank', 'health', 'healthcare', 'help', 'helsinki', 'here', 'hermes', 'hiphop', 'hisamitsu', 'hitachi', 'hiv', 'hk', 'hkt', 'hm', 'hn', 'hockey', 'holdings', 'holiday', 'homedepot', 'homegoods', 'homes', 'homesense', 'honda', 'horse', 'hospital', 'host', 'hosting', 'hot', 'hotels', 'hotmail', 'house', 'how', 'hr', 'hsbc', 'ht', 'hu', 'hughes', 'hyatt', 'hyundai',
  'ibm', 'icbc', 'ice', 'icu', 'id', 'ie', 'ieee', 'ifm', 'ikano', 'il', 'im', 'imamat', 'imdb', 'immo', 'immobilien', 'in', 'inc', 'industries', 'infiniti', 'info', 'ing', 'ink', 'institute', 'insurance', 'insure', 'int', 'international', 'intuit', 'investments', 'io', 'ipiranga', 'iq', 'ir', 'irish', 'is', 'ismaili', 'ist', 'istanbul', 'it', 'itau', 'itv',
  'jaguar', 'java', 'jcb', 'je', 'jeep', 'jetzt', 'jewelry', 'jio', 'jll', 'jm', 'jmp', 'jnj', 'jo', 'jobs', 'joburg', 'jot', 'joy', 'jp', 'jpmorgan', 'jprs', 'juegos', 'juniper',
  'kaufen', 'kddi', 'ke', 'kerryhotels', 'kerrylogistics', 'kerryproperties', 'kfh', 'kg', 'kh', 'ki', 'kia', 'kids', 'kim', 'kinder', 'kindle', 'kitchen', 'kiwi', 'km', 'kn', 'koeln', 'komatsu', 'kosher', 'kp', 'kpmg', 'kpn', 'kr', 'krd', 'kred', 'kuokgroup', 'kw', 'ky', 'kyoto', 'kz',
  'la', 'lacaixa', 'lamborghini', 'lamer', 'lancaster', 'land', 'landrover', 'lanxess', 'lasalle', 'lat', 'latino', 'latrobe', 'law', 'lawyer', 'lb', 'lc', 'lds', 'lease', 'leclerc', 'lefrak', 'legal', 'lego', 'lexus', 'lgbt', 'li', 'lidl', 'life', 'lifeinsurance', 'lifestyle', 'lighting', 'like', 'lilly', 'limited', 'limo', 'lincoln', 'link', 'lipsy', 'live', 'living', 'lk', 'llc', 'llp', 'loan', 'loans', 'locker', 'locus', 'lol', 'london', 'lotte', 'lotto', 'love', 'lpl', 'lplfinancial', 'lr', 'ls', 'lt', 'ltd', 'ltda', 'lu', 'lundbeck', 'luxe', 'luxury', 'lv', 'ly',
  'ma', 'madrid', 'maif', 'maison', 'makeup', 'man', 'management', 'mango', 'map', 'market', 'marketing', 'markets', 'marriott', 'marshalls', 'mattel', 'mba', 'mc', 'mckinsey', 'md', 'me', 'med', 'media', 'meet', 'melbourne', 'meme', 'memorial', 'men', 'menu', 'merckmsd', 'mg', 'mh', 'miami', 'microsoft', 'mil', 'mini', 'mint', 'mit', 'mitsubishi', 'mk', 'ml', 'mlb', 'mls', 'mm', 'mma', 'mn', 'mo', 'mobi', 'mobile', 'moda', 'moe', 'moi', 'mom', 'monash', 'money', 'monster', 'mormon', 'mortgage', 'moscow', 'moto', 'motorcycles', 'mov', 'movie', 'mp', 'mq', 'mr', 'ms', 'msd', 'mt', 'mtn', 'mtr', 'mu', 'museum', 'music', 'mutual', 'mv', 'mw', 'mx', 'my', 'mz',
  'na', 'nab', 'nagoya', 'name', 'natura', 'navy', 'nba', 'nc', 'ne', 'nec', 'net', 'netbank', 'netflix', 'network', 'neustar', 'new', 'news', 'next', 'nextdirect', 'nexus', 'nf', 'nfl', 'ng', 'ngo', 'nhk', 'ni', 'nico', 'nike', 'nikon', 'ninja', 'nissan', 'nissay', 'nl', 'no', 'nokia', 'northwesternmutual', 'norton', 'now', 'nowruz', 'nowtv', 'np', 'nr', 'nra', 'nrw', 'ntt', 'nu', 'nyc', 'nz',
  'obi', 'observer', 'office', 'okinawa', 'olayan', 'olayangroup', 'oldnavy', 'ollo', 'om', 'omega', 'one', 'ong', 'onl', 'online', 'ooo', 'open', 'oracle', 'orange', 'org', 'organic', 'origins', 'osaka', 'otsuka', 'ott', 'ovh',
  'pa', 'page', 'panasonic', 'paris', 'pars', 'partners', 'parts', 'party', 'pay', 'pccw', 'pe', 'pet', 'pf', 'pfizer', 'pg', 'ph', 'pharmacy', 'phd', 'philips', 'phone', 'photo', 'photography', 'photos', 'physio', 'pics', 'pictet', 'pictures', 'pid', 'pin', 'ping', 'pink', 'pioneer', 'pizza', 'pk', 'pl', 'place', 'play', 'playstation', 'plumbing', 'plus', 'pm', 'pn', 'pnc', 'pohl', 'poker', 'politie', 'porn', 'post', 'pr', 'pramerica', 'praxi', 'press', 'prime', 'pro', 'prod', 'productions', 'prof', 'progressive', 'promo', 'properties', 'property', 'protection', 'pru', 'prudential', 'ps', 'pt', 'pub', 'pw', 'pwc', 'py',
  'qa', 'qpon', 'quebec', 'quest',
  'racing', 'radio', 're', 'read', 'realestate', 'realtor', 'realty', 'recipes', 'red', 'redstone', 'redumbrella', 'rehab', 'reise', 'reisen', 'reit', 'reliance', 'ren', 'rent', 'rentals', 'repair', 'report', 'republican', 'rest', 'restaurant', 'review', 'reviews', 'rexroth', 'rich', 'richardli', 'ricoh', 'ril', 'rio', 'rip', 'ro', 'rocher', 'rocks', 'rodeo', 'rogers', 'room', 'rs', 'rsvp', 'ru', 'rugby', 'ruhr', 'run', 'rw', 'rwe', 'ryukyu',
  'sa', 'saarland', 'safe', 'safety', 'sakura', 'sale', 'salon', 'samsclub', 'samsung', 'sandvik', 'sandvikcoromant', 'sanofi', 'sap', 'sarl', 'sas', 'save', 'saxo', 'sb', 'sbi', 'sbs', 'sc', 'sca', 'scb', 'schaeffler', 'schmidt', 'scholarships', 'school', 'schule', 'schwarz', 'science', 'scot', 'sd', 'se', 'search', 'seat', 'secure', 'security', 'seek', 'select', 'sener', 'services', 'seven', 'sew', 'sex', 'sexy', 'sfr', 'sg', 'sh', 'shangrila', 'sharp', 'shaw', 'shell', 'shia', 'shiksha', 'shoes', 'shop', 'shopping', 'shouji', 'show', 'showtime', 'si', 'silk', 'sina', 'singles', 'site', 'sj', 'sk', 'ski', 'skin', 'sky', 'skype', 'sl', 'sling', 'sm', 'smart', 'smile', 'sn', 'sncf', 'so', 'soccer', 'social', 'softbank', 'software', 'sohu', 'solar', 'solutions', 'song', 'sony', 'soy', 'spa', 'space', 'sport', 'spot', 'sr', 'srl', 'ss', 'st', 'stada', 'staples', 'star', 'statebank', 'statefarm', 'stc', 'stcgroup', 'stockholm', 'storage', 'store', 'stream', 'studio', 'study', 'style', 'su', 'sucks', 'supplies', 'supply', 'support', 'surf', 'surgery', 'suzuki', 'sv', 'swatch', 'swiss', 'sx', 'sy', 'sydney', 'systems', 'sz',
  'tab', 'taipei', 'talk', 'taobao', 'target', 'tatamotors', 'tatar', 'tattoo', 'tax', 'taxi', 'tc', 'tci', 'td', 'tdk', 'team', 'tech', 'technology', 'tel', 'temasek', 'tennis', 'teva', 'tf', 'tg', 'th', 'thd', 'theater', 'theatre', 'tiaa', 'tickets', 'tienda', 'tiffany', 'tips', 'tires', 'tirol', 'tj', 'tjmaxx', 'tjx', 'tk', 'tkmaxx', 'tl', 'tm', 'tmall', 'tn', 'to', 'today', 'tokyo', 'tools', 'top', 'toray', 'toshiba', 'total', 'tours', 'town', 'toyota', 'toys', 'tr', 'trade', 'trading', 'training', 'travel', 'travelers', 'travelersinsurance', 'trust', 'trv', 'tt', 'tube', 'tui', 'tunes', 'tushu', 'tv', 'tvs', 'tw', 'tz',
  'ua', 'ubank', 'ubs', 'ug', 'uk', 'unicom', 'university', 'uno', 'uol', 'ups', 'us', 'uy', 'uz',
  'va', 'vacations', 'vana', 'vanguard', 'vc', 've', 'vegas', 'ventures', 'verisign', 'versicherung', 'vet', 'vg', 'vi', 'viajes', 'video', 'vig', 'viking', 'villas', 'vin', 'vip', 'virgin', 'visa', 'vision', 'viva', 'vivo', 'vlaanderen', 'vn', 'vodka', 'volkswagen', 'volvo', 'vote', 'voting', 'voto', 'voyage', 'vu',
  'wales', 'walmart', 'walter', 'wang', 'wanggou', 'watch', 'watches', 'weather', 'weatherchannel', 'webcam', 'weber', 'website', 'wed', 'wedding', 'weibo', 'weir', 'wf', 'whoswho', 'wien', 'wiki', 'williamhill', 'win', 'windows', 'wine', 'winners', 'wme', 'wolterskluwer', 'woodside', 'work', 'works', 'world', 'wow', 'ws', 'wtc', 'wtf',
  'xbox', 'xerox', 'xfinity', 'xihuan', 'xin', 'xxx', 'xyz',
  'yachts', 'yahoo', 'yamaxun', 'yandex', 'ye', 'yodobashi', 'yoga', 'yokohama', 'you', 'youtube', 'yt', 'yun',
  'za', 'zappos', 'zara', 'zero', 'zip', 'zm', 'zone', 'zuerich', 'zw'
};

final _escapeSymbolPattern = RegExp(r'''\\([!"#$%&'()*+,\-./:;<=>?@\[\\\]^_`{|}~])''');

extension _LastChar on String {
  String? get firstChar {
    if (isEmpty) {
      return null;
    }
    return this[0];
  }
  String? get lastChar {
    if (isEmpty) {
      return null;
    }
    return this[length - 1];
  }
}

class LooseUrlLinkifier extends Linkifier {
  final bool unescapeBackslashes;
  /// Skip "$link" (avoid HTML attribute values)
  /// Skip >$link</a> (avoid double-linking)
  /// Skip [$link]( (avoid double-linking)
  /// Skip ]($link) (avoid double-linking)
  final bool redditSafeMode;
  const LooseUrlLinkifier({
    this.unescapeBackslashes = false,
    this.redditSafeMode = false
  });

  String _handleBackslashes(String str) {
    if (!unescapeBackslashes) {
      return str;
    }
    return str.replaceAllMapped(_escapeSymbolPattern, (m) => m.group(1)!);
  }

  @override
  List<LinkifyElement> parse(elements, options) {
    final list = <LinkifyElement>[];

    for (final element in elements) {
      if (element is TextElement) {
        final matches = (unescapeBackslashes ? _looseUrlRegexWithBackslash : _looseUrlRegex).allMatches(element.text);
        int lastMatchEnd = 0;

        for (final match in matches) {
          final domain = match.group(2);
          if ((domain?.contains('..') ?? false) || !_validTlds.contains((domain ?? '').afterLast('.').toLowerCase())) {
            // Invalid domain name
            continue;
          }
          if (redditSafeMode) {
            final before = match.start > 0 ? element.text.substring(0, match.start) : null;
            final after = match.end < element.text.length ? element.text.substring(match.end) : null;
            if (before != null && after != null) {
              if (before.lastChar == '"' && after.firstChar == '"') {
                // "$link"
                continue;
              }
              if (before.lastChar == '>' && after.startsWith('</a>')) {
                // >$link</a>
                continue;
              }
              if (before.contains('[') && after.startsWith('](')) {
                // [$link](
                continue;
              }
              if (
                before.contains('[')
                && !before.contains(']')
                && !(match.group(0)?.contains('/') ?? false) // not a full URL
                && switch (after.indexOf(']')) {
                  -1 => false, // No closing bracket
                  // The closing bracket is not for a separate link
                  int index => after.indexOf('[') < index
                }
              ) {
                // [... $host](
                // Sometimes people note the site in a markdown URL label
                continue;
              }
            }
            if (
                // TODO: Optimize
                (before?.trimRight().endsWith('](') ?? false)
                && (
                  (match.group(0)?.contains(')') ?? false)
                  || after?.firstChar == ')'
                )
              ) {
                // ]($link)
                continue;
              }
            if ('```'.allMatches(before ?? '').length % 2 == 1) {
              /// ``` $host ```
              continue;
            }
          }

          if (match.start > lastMatchEnd) {
            list.add(TextElement(element.text.substring(lastMatchEnd, match.start)));
          }
          lastMatchEnd = match.end;

          String originalUrl = _handleBackslashes(match.group(0)!);
          String end = '';

          /// (... $link)
          if (
                originalUrl.endsWith(')')
                && (element.text.lastIndexOf('(', match.start) > element.text.lastIndexOf(')', match.start))
          ) {
            end = ')$end';
            originalUrl = originalUrl.substring(0, originalUrl.length - 1);
          }

          if (options.excludeLastPeriod) {
            int c = 0;
            for (; c < originalUrl.length - 1; c++) {
              if (originalUrl[originalUrl.length - (c + 1)] != '.') {
                break;
              }
            }
            if (c > 0) {
              end = ('.' * c) + end;
              originalUrl = originalUrl.substring(0, originalUrl.length - c);
            }
          }

          String url = originalUrl;

          if (!originalUrl.startsWith(_protocolIdentifierRegex)) {
            originalUrl = (options.defaultToHttps ? "https://" : "http://") +
                originalUrl;
          }

          if ((options.humanize) || (options.removeWww)) {
            if (options.humanize) {
              // Don't use "s?", still show http:// if that's the explicit protocol
              url = url.replaceFirst(RegExp(r'https://'), '');
            }
            if (options.removeWww) {
              url = url.replaceFirst(RegExp(r'www\.'), '');
            }

            list.add(UrlElement(
              originalUrl,
              url,
            ));
          } else {
            list.add(UrlElement(originalUrl));
          }

          if (end.isNotEmpty) {
            list.add(TextElement(end));
          }
        }
        if (lastMatchEnd < element.text.length) {
          list.add(TextElement(element.text.substring(lastMatchEnd)));
        }
      } else {
        list.add(element);
      }
    }

    return list;
  }
}
