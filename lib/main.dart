import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:screenshot/screenshot.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

const Color kDark = Color(0xFF222222);
const Color kRed = Color(0xFFC9131F);
const Color kLight = Color(0xFFF6F6F6);

String cleanHtml(dynamic value) {
  final raw = value?.toString() ?? '';
  return html_parser.parse(raw).documentElement?.text.trim() ?? raw;
}

String money(dynamic value, [String symbol = '£']) {
  final amount = double.tryParse(value?.toString() ?? '') ?? 0;
  return '$symbol${NumberFormat('#,##0.00').format(amount)}';
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const PTIApp());
}

class ApiClient {
  static const FlutterSecureStorage storage = FlutterSecureStorage();

  String baseUrl = '';
  String username = '';
  String appPassword = '';

  Map<String, String> get headers => <String, String>{
        'Authorization':
            'Basic ${base64Encode(utf8.encode('$username:$appPassword'))}',
        'Accept': 'application/json',
        'Content-Type': 'application/json',
      };

  Uri endpoint(String path, [Map<String, String>? query]) {
    final cleanBase = baseUrl.replaceAll(RegExp(r'/+$'), '');
    return Uri.parse('$cleanBase/wp-json/pti-pos/v1$path')
        .replace(queryParameters: query);
  }

  Future<bool> loadSavedCredentials() async {
    final prefs = await SharedPreferences.getInstance();
    final remember = prefs.getBool('remember_login') ?? false;
    if (!remember) return false;

    baseUrl = await storage.read(key: 'base_url') ?? '';
    username = await storage.read(key: 'username') ?? '';
    appPassword = await storage.read(key: 'app_password') ?? '';

    return baseUrl.isNotEmpty &&
        username.isNotEmpty &&
        appPassword.isNotEmpty;
  }

  Future<void> saveCredentials({
    required String site,
    required String user,
    required String password,
    required bool remember,
  }) async {
    baseUrl = site.trim().replaceAll(RegExp(r'/+$'), '');
    username = user.trim();
    appPassword = password.replaceAll(' ', '').trim();

    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('remember_login', remember);

    if (remember) {
      await storage.write(key: 'base_url', value: baseUrl);
      await storage.write(key: 'username', value: username);
      await storage.write(key: 'app_password', value: appPassword);
    } else {
      await storage.deleteAll();
    }
  }

  Future<void> logout({bool forget = false}) async {
    if (!forget) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('remember_login', false);
    await storage.deleteAll();
    baseUrl = '';
    username = '';
    appPassword = '';
  }

  Future<dynamic> get(
    String path, [
    Map<String, String>? query,
  ]) async {
    try {
      final response = await http
          .get(endpoint(path, query), headers: headers)
          .timeout(const Duration(seconds: 35));
      return _decode(response);
    } on SocketException {
      throw Exception(
        'Internet ya DNS connection available nahi. Wi-Fi/mobile data check karein.',
      );
    } on TimeoutException {
      throw Exception('Server response timeout. Dobara try karein.');
    }
  }

  Future<dynamic> post(
    String path,
    Map<String, dynamic> body,
  ) async {
    try {
      final response = await http
          .post(
            endpoint(path),
            headers: headers,
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 35));
      return _decode(response);
    } on SocketException {
      throw Exception('Internet connection available nahi.');
    } on TimeoutException {
      throw Exception('Server response timeout.');
    }
  }

  Future<dynamic> patch(
    String path,
    Map<String, dynamic> body,
  ) async {
    try {
      final response = await http
          .patch(
            endpoint(path),
            headers: headers,
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 35));
      return _decode(response);
    } on SocketException {
      throw Exception('Internet connection available nahi.');
    } on TimeoutException {
      throw Exception('Server response timeout.');
    }
  }

  Future<dynamic> uploadMedia(XFile file) async {
    final request = http.MultipartRequest('POST', endpoint('/media'));
    request.headers['Authorization'] = headers['Authorization']!;
    request.files.add(
      await http.MultipartFile.fromPath('file', file.path),
    );

    final streamed =
        await request.send().timeout(const Duration(seconds: 90));
    final response = await http.Response.fromStream(streamed);
    return _decode(response);
  }

  dynamic _decode(http.Response response) {
    dynamic payload;
    try {
      payload = jsonDecode(response.body);
    } catch (_) {
      payload = null;
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      final message = payload is Map
          ? payload['message']?.toString()
          : 'Request failed (${response.statusCode})';
      throw Exception(cleanHtml(message ?? 'Request failed'));
    }

    return payload;
  }
}

final ApiClient api = ApiClient();

class PTIApp extends StatefulWidget {
  const PTIApp({super.key});

  @override
  State<PTIApp> createState() => _PTIAppState();
}

class _PTIAppState extends State<PTIApp> {
  bool loading = true;
  bool loggedIn = false;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    final hasCredentials = await api.loadSavedCredentials();

    if (hasCredentials) {
      try {
        await api.get('/me');
        loggedIn = true;
      } catch (_) {
        loggedIn = false;
      }
    }

    if (mounted) {
      setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: kRed,
      primary: kRed,
      surface: Colors.white,
    );

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Pet Trade Innovations',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: colorScheme,
        scaffoldBackgroundColor: kLight,
        textTheme: GoogleFonts.interTextTheme(),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.white,
          foregroundColor: kDark,
          elevation: 0,
          centerTitle: false,
        ),
        cardTheme: CardThemeData(
          color: Colors.white,
          elevation: 0,
          margin: EdgeInsets.zero,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
            side: BorderSide(color: Colors.grey.shade200),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: Colors.white,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide(color: Colors.grey.shade300),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide(color: Colors.grey.shade300),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: kRed, width: 1.5),
          ),
        ),
      ),
      home: loading
          ? const BrandedLoader()
          : loggedIn
              ? MainShell(
                  onLogout: () async {
                    await api.logout(forget: false);
                    if (mounted) setState(() => loggedIn = false);
                  },
                  onForget: () async {
                    await api.logout(forget: true);
                    if (mounted) setState(() => loggedIn = false);
                  },
                )
              : LoginScreen(
                  onSuccess: () {
                    setState(() => loggedIn = true);
                  },
                ),
    );
  }
}

class BrandedLoader extends StatelessWidget {
  const BrandedLoader({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            SvgPicture.asset(
              'assets/pti-logo.svg',
              width: 220,
            ),
            const SizedBox(height: 24),
            const CircularProgressIndicator(color: kRed),
          ],
        ),
      ),
    );
  }
}

class LoginScreen extends StatefulWidget {
  final VoidCallback onSuccess;

  const LoginScreen({
    super.key,
    required this.onSuccess,
  });

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  @override
  void initState() {
    super.initState();
    _prefill();
  }

  Future<void> _prefill() async {
    final savedSite = await ApiClient.storage.read(key: 'base_url');
    final savedUser = await ApiClient.storage.read(key: 'username');
    final savedPassword = await ApiClient.storage.read(key: 'app_password');
    if (!mounted) return;
    if ((savedSite ?? '').isNotEmpty) siteController.text = savedSite!;
    if ((savedUser ?? '').isNotEmpty) userController.text = savedUser!;
    if ((savedPassword ?? '').isNotEmpty) passwordController.text = savedPassword!;
    setState(() {});
  }

  final siteController =
      TextEditingController(text: 'https://teddoeszoomies.co.uk');
  final userController = TextEditingController();
  final passwordController = TextEditingController();

  bool rememberMe = true;
  bool hidePassword = true;
  bool busy = false;
  String? error;

  @override
  void dispose() {
    siteController.dispose();
    userController.dispose();
    passwordController.dispose();
    super.dispose();
  }

  Future<void> login() async {
    FocusScope.of(context).unfocus();

    if (siteController.text.trim().isEmpty ||
        userController.text.trim().isEmpty ||
        passwordController.text.trim().isEmpty) {
      setState(() => error = 'Tamam fields fill karein.');
      return;
    }

    setState(() {
      busy = true;
      error = null;
    });

    try {
      await api.saveCredentials(
        site: siteController.text,
        user: userController.text,
        password: passwordController.text,
        remember: rememberMe,
      );

      await api.get('/me');
      widget.onSuccess();
    } catch (e) {
      setState(
        () => error = e.toString().replaceFirst('Exception: ', ''),
      );
    } finally {
      if (mounted) {
        setState(() => busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: <Color>[
              Colors.white,
              Colors.grey.shade100,
              const Color(0xFFFFF1F2),
            ],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 480),
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(28, 32, 28, 26),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        SvgPicture.asset(
                          'assets/pti-logo.svg',
                          height: 72,
                        ),
                        const SizedBox(height: 22),
                        Text(
                          'PTI Premium POS',
                          style: Theme.of(context)
                              .textTheme
                              .headlineSmall
                              ?.copyWith(fontWeight: FontWeight.w800),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'Secure WooCommerce management anywhere',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.grey.shade600),
                        ),
                        const SizedBox(height: 28),
                        TextField(
                          controller: siteController,
                          keyboardType: TextInputType.url,
                          decoration: const InputDecoration(
                            labelText: 'Website URL',
                            prefixIcon: Icon(Icons.language),
                          ),
                        ),
                        const SizedBox(height: 14),
                        TextField(
                          controller: userController,
                          decoration: const InputDecoration(
                            labelText: 'WordPress Username',
                            prefixIcon: Icon(Icons.person_outline),
                          ),
                        ),
                        const SizedBox(height: 14),
                        TextField(
                          controller: passwordController,
                          obscureText: hidePassword,
                          onSubmitted: (_) => busy ? null : login(),
                          decoration: InputDecoration(
                            labelText: 'Application Password',
                            prefixIcon: const Icon(Icons.lock_outline),
                            suffixIcon: IconButton(
                              onPressed: () {
                                setState(
                                  () => hidePassword = !hidePassword,
                                );
                              },
                              icon: Icon(
                                hidePassword
                                    ? Icons.visibility_outlined
                                    : Icons.visibility_off_outlined,
                              ),
                            ),
                          ),
                        ),
                        CheckboxListTile(
                          value: rememberMe,
                          contentPadding: EdgeInsets.zero,
                          activeColor: kRed,
                          title: const Text('Remember me'),
                          subtitle: const Text(
                            'Login details securely save hongi',
                          ),
                          onChanged: (value) {
                            setState(
                              () => rememberMe = value ?? true,
                            );
                          },
                        ),
                        if (error != null)
                          Container(
                            width: double.infinity,
                            margin: const EdgeInsets.only(bottom: 14),
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: kRed.withValues(alpha: 0.08),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Text(
                              error!,
                              style: const TextStyle(color: kRed),
                            ),
                          ),
                        SizedBox(
                          width: double.infinity,
                          height: 52,
                          child: FilledButton.icon(
                            onPressed: busy ? null : login,
                            style: FilledButton.styleFrom(
                              backgroundColor: kRed,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14),
                              ),
                            ),
                            icon: busy
                                ? const SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white,
                                    ),
                                  )
                                : const Icon(Icons.login),
                            label: Text(
                              busy ? 'Connecting...' : 'Connect securely',
                            ),
                          ),
                        ),
                        const SizedBox(height: 20),
                        const Text(
                          'Version 1.0',
                          style: TextStyle(fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class OrderNotificationService {
  static final FlutterLocalNotificationsPlugin plugin = FlutterLocalNotificationsPlugin();
  static Timer? timer;

  static Future<void> start() async {
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const settings = InitializationSettings(android: android);
    await plugin.initialize(settings);
    await plugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();
    await check();
    timer?.cancel();
    timer = Timer.periodic(const Duration(seconds: 60), (_) => check());
  }

  static Future<void> stop() async {
    timer?.cancel();
    timer = null;
  }

  static Future<void> check() async {
    try {
      final result = await api.get('/orders', <String, String>{'page': '1', 'per_page': '1'});
      final items = List<dynamic>.from(result['items'] ?? <dynamic>[]);
      if (items.isEmpty) return;
      final order = Map<String, dynamic>.from(items.first as Map);
      final currentId = int.tryParse('${order['id']}') ?? 0;
      final prefs = await SharedPreferences.getInstance();
      final lastId = prefs.getInt('last_notified_order_id') ?? 0;
      if (lastId == 0) {
        await prefs.setInt('last_notified_order_id', currentId);
        return;
      }
      if (currentId > lastId) {
        final symbol = cleanHtml(order['currency_symbol']).isEmpty ? '£' : cleanHtml(order['currency_symbol']);
        const details = NotificationDetails(
          android: AndroidNotificationDetails(
            'pti_new_orders',
            'New WooCommerce Orders',
            channelDescription: 'Notifications for new PTI WooCommerce orders',
            importance: Importance.max,
            priority: Priority.high,
          ),
        );
        await plugin.show(
          currentId,
          'New Order #${order['number']}',
          '${cleanHtml(order['customer_name'])} • ${money(order['total'], symbol)}',
          details,
        );
        await prefs.setInt('last_notified_order_id', currentId);
      }
    } catch (_) {}
  }
}

class MainShell extends StatefulWidget {
  final VoidCallback onLogout;
  final VoidCallback onForget;

  const MainShell({
    super.key,
    required this.onLogout,
    required this.onForget,
  });

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int selectedIndex = 0;

  @override
  void initState() {
    super.initState();
    OrderNotificationService.start();
  }

  @override
  void dispose() {
    OrderNotificationService.stop();
    super.dispose();
  }

  final List<Widget> pages = const <Widget>[
    DashboardScreen(),
    OrdersScreen(),
    ProductsScreen(),
    PosScreen(),
  ];

  final List<String> labels = const <String>[
    'Dashboard',
    'Orders',
    'Products',
    'POS',
  ];

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 900;

    final scaffold = Scaffold(
      appBar: AppBar(
        title: Row(
          children: <Widget>[
            SvgPicture.asset(
              'assets/pti-logo.svg',
              height: 34,
            ),
            const SizedBox(width: 14),
            if (MediaQuery.sizeOf(context).width > 560)
              Text(
                labels[selectedIndex],
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
          ],
        ),
        actions: <Widget>[
          IconButton(
            tooltip: 'About App',
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => const AboutScreen(),
                ),
              );
            },
            icon: const Icon(Icons.info_outline),
          ),
          PopupMenuButton<String>(
            onSelected: (value) {
              if (value == 'logout') widget.onLogout();
              if (value == 'forget') widget.onForget();
            },
            itemBuilder: (_) => const <PopupMenuEntry<String>>[
              PopupMenuItem<String>(
                value: 'logout',
                child: ListTile(leading: Icon(Icons.logout), title: Text('Logout (keep details)')),
              ),
              PopupMenuItem<String>(
                value: 'forget',
                child: ListTile(leading: Icon(Icons.delete_outline), title: Text('Logout & forget details')),
              ),
            ],
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: IndexedStack(
        index: selectedIndex,
        children: pages,
      ),
      bottomNavigationBar: wide
          ? null
          : NavigationBar(
              selectedIndex: selectedIndex,
              indicatorColor: kRed.withValues(alpha: 0.12),
              onDestinationSelected: (value) {
                setState(() => selectedIndex = value);
              },
              destinations: const <NavigationDestination>[
                NavigationDestination(
                  icon: Icon(Icons.dashboard_outlined),
                  selectedIcon: Icon(Icons.dashboard),
                  label: 'Dashboard',
                ),
                NavigationDestination(
                  icon: Icon(Icons.receipt_long_outlined),
                  selectedIcon: Icon(Icons.receipt_long),
                  label: 'Orders',
                ),
                NavigationDestination(
                  icon: Icon(Icons.inventory_2_outlined),
                  selectedIcon: Icon(Icons.inventory_2),
                  label: 'Products',
                ),
                NavigationDestination(
                  icon: Icon(Icons.point_of_sale_outlined),
                  selectedIcon: Icon(Icons.point_of_sale),
                  label: 'POS',
                ),
              ],
            ),
    );

    if (!wide) return scaffold;

    return Scaffold(
      body: Row(
        children: <Widget>[
          NavigationRail(
            backgroundColor: kDark,
            selectedIndex: selectedIndex,
            labelType: NavigationRailLabelType.all,
            onDestinationSelected: (value) {
              setState(() => selectedIndex = value);
            },
            leading: Padding(
              padding: const EdgeInsets.symmetric(vertical: 18),
              child: Image.asset(
                'assets/app-icon.png',
                width: 48,
                height: 48,
                errorBuilder: (_, __, ___) => const Icon(
                  Icons.pets,
                  color: Colors.white,
                  size: 36,
                ),
              ),
            ),
            selectedIconTheme:
                const IconThemeData(color: Colors.white),
            unselectedIconTheme:
                const IconThemeData(color: Colors.white70),
            selectedLabelTextStyle: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w700,
            ),
            unselectedLabelTextStyle:
                const TextStyle(color: Colors.white70),
            destinations: const <NavigationRailDestination>[
              NavigationRailDestination(
                icon: Icon(Icons.dashboard_outlined),
                selectedIcon: Icon(Icons.dashboard),
                label: Text('Dashboard'),
              ),
              NavigationRailDestination(
                icon: Icon(Icons.receipt_long_outlined),
                selectedIcon: Icon(Icons.receipt_long),
                label: Text('Orders'),
              ),
              NavigationRailDestination(
                icon: Icon(Icons.inventory_2_outlined),
                selectedIcon: Icon(Icons.inventory_2),
                label: Text('Products'),
              ),
              NavigationRailDestination(
                icon: Icon(Icons.point_of_sale_outlined),
                selectedIcon: Icon(Icons.point_of_sale),
                label: Text('POS'),
              ),
            ],
          ),
          Expanded(child: scaffold),
        ],
      ),
    );
  }
}

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});
  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  dynamic dashboard;
  List<dynamic> customers = <dynamic>[];
  String? error;
  String preset = 'Today';
  DateTimeRange? customRange;

  @override
  void initState() { super.initState(); load(); }

  Map<String, String> get rangeQuery {
    final now = DateTime.now();
    DateTime from; DateTime to = now;
    switch (preset) {
      case 'Yesterday':
        from = DateTime(now.year, now.month, now.day).subtract(const Duration(days: 1));
        to = from;
        break;
      case 'Last 7 Days': from = now.subtract(const Duration(days: 6)); break;
      case 'Last 30 Days': from = now.subtract(const Duration(days: 29)); break;
      case 'This Month': from = DateTime(now.year, now.month, 1); break;
      case 'All Time': return <String, String>{};
      case 'Custom':
        if (customRange == null) return <String, String>{};
        from = customRange!.start; to = customRange!.end; break;
      default: from = DateTime(now.year, now.month, now.day);
    }
    return <String, String>{'from': DateFormat('yyyy-MM-dd').format(from), 'to': DateFormat('yyyy-MM-dd').format(to)};
  }

  Future<void> chooseCustom() async {
    final now = DateTime.now();
    final picked = await showDateRangePicker(context: context, firstDate: DateTime(2020), lastDate: now.add(const Duration(days: 1)), initialDateRange: customRange ?? DateTimeRange(start: now.subtract(const Duration(days: 6)), end: now));
    if (picked != null) { setState(() { customRange = picked; preset = 'Custom'; }); load(); }
  }

  Future<void> load() async {
    try {
      final results = await Future.wait<dynamic>(<Future<dynamic>>[
        api.get('/dashboard', rangeQuery),
        api.get('/customers', <String, String>{'page':'1','per_page':'3'}),
      ]);
      dashboard = results[0];
      final c = results[1];
      customers = c is Map ? List<dynamic>.from(c['items'] ?? <dynamic>[]) : List<dynamic>.from(c ?? <dynamic>[]);
      error = null;
    } catch(e) { error = e.toString().replaceFirst('Exception: ', ''); }
    if(mounted) setState((){});
  }

  @override
  Widget build(BuildContext context) {
    if(dashboard==null && error==null) return const Center(child:CircularProgressIndicator(color:kRed));
    if(error!=null) return ErrorPanel(message:error!, retry:load);
    final raw=cleanHtml(dashboard['currency_symbol']); final symbol=raw.isEmpty?'£':raw;
    return RefreshIndicator(onRefresh:load,color:kRed,child:LayoutBuilder(builder:(context,constraints){
      final columns=constraints.maxWidth>=1100?4:constraints.maxWidth>=650?2:1;
      return ListView(padding:const EdgeInsets.all(20),children:<Widget>[
        Row(children:<Widget>[
          Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:<Widget>[
            Text('Business overview',style:Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight:FontWeight.w800)),
            const SizedBox(height:4), Text('Orders and sales for selected date range',style:TextStyle(color:Colors.grey.shade600)),
          ])),
          IconButton.filledTonal(onPressed:load,icon:const Icon(Icons.refresh)),
        ]),
        const SizedBox(height:14),
        Wrap(spacing:8,runSpacing:8,children:<Widget>[
          ...['Today','Yesterday','Last 7 Days','Last 30 Days','This Month','All Time'].map((x)=>ChoiceChip(label:Text(x),selected:preset==x,onSelected:(_){setState(()=>preset=x);load();})),
          ActionChip(avatar:const Icon(Icons.date_range,size:18),label:Text(preset=='Custom'&&customRange!=null?'${DateFormat('dd MMM').format(customRange!.start)} - ${DateFormat('dd MMM').format(customRange!.end)}':'Custom'),onPressed:chooseCustom),
        ]),
        const SizedBox(height:18),
        GridView.count(crossAxisCount:columns,shrinkWrap:true,physics:const NeverScrollableScrollPhysics(),crossAxisSpacing:14,mainAxisSpacing:14,childAspectRatio:columns==1?2.7:1.8,children:<Widget>[
          MetricCard(title:'Total Orders',value:'${dashboard['total_orders']??0}',icon:Icons.shopping_bag_outlined),
          MetricCard(title:'Total Sales',value:money(dashboard['total_sales'],symbol),icon:Icons.payments_outlined),
          MetricCard(title:'Average Order',value:money(dashboard['average_order_value'],symbol),icon:Icons.analytics_outlined),
          MetricCard(title:'Open Orders',value:'${dashboard['open_orders']??0}',icon:Icons.pending_actions_outlined),
          MetricCard(title:'Completed',value:'${dashboard['completed_orders']??0}',icon:Icons.task_alt),
          MetricCard(title:'Pending',value:'${dashboard['pending_orders']??0}',icon:Icons.schedule),
          MetricCard(title:'Refunded',value:'${dashboard['refunded_orders']??0}',icon:Icons.currency_exchange),
          MetricCard(title:'Low Stock',value:'${dashboard['low_stock']??0}',icon:Icons.warning_amber_rounded),
        ]),
        const SizedBox(height:22),
        SectionCard(title:'Recent Customers',subtitle:'Latest customer accounts',child:customers.isEmpty?const Padding(padding:EdgeInsets.all(24),child:Center(child:Text('No customers found'))):Column(children:customers.map<Widget>((raw){final c=Map<String,dynamic>.from(raw as Map);final name=cleanHtml(c['name']);return ListTile(contentPadding:const EdgeInsets.symmetric(horizontal:4),leading:CircleAvatar(backgroundColor:kRed.withValues(alpha:.1),child:Text(name.isNotEmpty?name[0].toUpperCase():'C',style:const TextStyle(color:kRed,fontWeight:FontWeight.bold))),title:Text(name,style:const TextStyle(fontWeight:FontWeight.w700)),subtitle:Text(cleanHtml(c['email'])),trailing:Text('${c['orders_count']??0} orders'));}).toList())),
        const SizedBox(height:24), const DeveloperFooter(),
      ]);
    }));
  }
}

class MetricCard extends StatelessWidget {
  final String title;
  final String value;
  final IconData icon;

  const MetricCard({
    super.key,
    required this.title,
    required this.value,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Row(
          children: <Widget>[
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: kRed.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Icon(icon, color: kRed),
            ),
            const SizedBox(width: 15),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    value,
                    style: const TextStyle(
                      fontSize: 23,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    title,
                    style: TextStyle(
                      color: Colors.grey.shade600,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class OrdersScreen extends StatefulWidget {
  const OrdersScreen({super.key});

  @override
  State<OrdersScreen> createState() => _OrdersScreenState();
}

class _OrdersScreenState extends State<OrdersScreen> {
  final TextEditingController searchController = TextEditingController();

  Timer? debounce;
  List<dynamic> orders = <dynamic>[];
  bool loading = true;
  String? error;
  int page = 1;
  int totalPages = 1;

  @override
  void initState() {
    super.initState();
    searchController.addListener(_searchChanged);
    load();
  }

  void _searchChanged() {
    debounce?.cancel();
    debounce = Timer(const Duration(milliseconds: 450), () {
      page = 1;
      load();
    });
    setState(() {});
  }

  @override
  void dispose() {
    debounce?.cancel();
    searchController.dispose();
    super.dispose();
  }

  Future<void> load() async {
    if (mounted) setState(() => loading = true);

    try {
      final result = await api.get('/orders', <String, String>{
        'page': '$page',
        'per_page': '20',
        'search': searchController.text.trim(),
      });

      orders = List<dynamic>.from(result['items'] ?? <dynamic>[]);
      totalPages =
          int.tryParse('${result['total_pages'] ?? 1}') ?? 1;
      error = null;
    } catch (e) {
      error = e.toString().replaceFirst('Exception: ', '');
    }

    if (mounted) setState(() => loading = false);
  }

  Future<void> shareOrder(Map<String, dynamic> order) async {
    final symbol =
        cleanHtml(order['currency_symbol'] ?? order['currency']);
    final text = <String>[
      'Order #${order['number']}',
      'Customer: ${cleanHtml(order['customer_name'])}',
      'Status: ${cleanHtml(order['status'])}',
      'Total: ${money(order['total'], symbol.isEmpty ? '£' : symbol)}',
    ].join('\n');

    final uri =
        Uri.parse('https://wa.me/?text=${Uri.encodeComponent(text)}');
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
          child: Row(
            children: <Widget>[
              Expanded(
                child: TextField(
                  controller: searchController,
                  decoration: InputDecoration(
                    hintText:
                        'Live search by order, customer, email...',
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: searchController.text.isNotEmpty
                        ? IconButton(
                            onPressed: searchController.clear,
                            icon: const Icon(Icons.clear),
                          )
                        : null,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              IconButton.filledTonal(
                onPressed: load,
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
        ),
        Expanded(
          child: loading
              ? const Center(
                  child: CircularProgressIndicator(color: kRed),
                )
              : error != null
                  ? ErrorPanel(message: error!, retry: load)
                  : RefreshIndicator(
                      onRefresh: load,
                      child: orders.isEmpty
                          ? ListView(
                              children: const <Widget>[
                                SizedBox(height: 150),
                                Center(
                                  child: Text('No orders found'),
                                ),
                              ],
                            )
                          : ListView.separated(
                              padding:
                                  const EdgeInsets.fromLTRB(20, 4, 20, 16),
                              itemCount: orders.length,
                              separatorBuilder: (_, __) =>
                                  const SizedBox(height: 10),
                              itemBuilder: (context, index) {
                                final order =
                                    Map<String, dynamic>.from(
                                  orders[index] as Map,
                                );

                                final rawSymbol = cleanHtml(
                                  order['currency_symbol'] ??
                                      order['currency'],
                                );
                                final symbol =
                                    rawSymbol.isEmpty ? '£' : rawSymbol;

                                return Card(
                                  child: InkWell(
                                    borderRadius:
                                        BorderRadius.circular(18),
                                    onTap: () async {
                                      await Navigator.push(
                                        context,
                                        MaterialPageRoute<void>(
                                          builder: (_) =>
                                              OrderDetailScreen(
                                            id: order['id'],
                                          ),
                                        ),
                                      );
                                      load();
                                    },
                                    child: Padding(
                                      padding: const EdgeInsets.all(16),
                                      child: Row(
                                        children: <Widget>[
                                          Container(
                                            width: 48,
                                            height: 48,
                                            decoration: BoxDecoration(
                                              color: kDark,
                                              borderRadius:
                                                  BorderRadius.circular(14),
                                            ),
                                            child: const Icon(
                                              Icons.receipt_long,
                                              color: Colors.white,
                                            ),
                                          ),
                                          const SizedBox(width: 14),
                                          Expanded(
                                            child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: <Widget>[
                                                Wrap(
                                                  crossAxisAlignment:
                                                      WrapCrossAlignment.center,
                                                  spacing: 8,
                                                  runSpacing: 6,
                                                  children: <Widget>[
                                                    Text(
                                                      '#${order['number']}',
                                                      style:
                                                          const TextStyle(
                                                        fontWeight:
                                                            FontWeight.w800,
                                                        fontSize: 16,
                                                      ),
                                                    ),
                                                    StatusChip(
                                                      status: cleanHtml(
                                                        order['status'],
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                                const SizedBox(height: 6),
                                                Text(
                                                  cleanHtml(
                                                    order['customer_name'],
                                                  ),
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style:
                                                      const TextStyle(
                                                    fontWeight:
                                                        FontWeight.w600,
                                                  ),
                                                ),
                                                Text(
                                                  '${order['item_count'] ?? 0} items • ${cleanHtml(order['date_created'] ?? '')}',
                                                  style: TextStyle(
                                                    color:
                                                        Colors.grey.shade600,
                                                    fontSize: 12,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.end,
                                            children: <Widget>[
                                              Text(
                                                money(
                                                  order['total'],
                                                  symbol,
                                                ),
                                                style:
                                                    const TextStyle(
                                                  fontWeight:
                                                      FontWeight.w800,
                                                  fontSize: 16,
                                                ),
                                              ),
                                              IconButton(
                                                tooltip:
                                                    'Share on WhatsApp',
                                                onPressed: () =>
                                                    shareOrder(order),
                                                icon: const Icon(
                                                  Icons.share,
                                                  color:
                                                      Color(0xFF128C7E),
                                                ),
                                              ),
                                            ],
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                );
                              },
                            ),
                    ),
        ),
        if (!loading && error == null && totalPages > 1)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 14),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                IconButton.filledTonal(
                  onPressed: page > 1
                      ? () {
                          page--;
                          load();
                        }
                      : null,
                  icon: const Icon(Icons.chevron_left),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  child: Text(
                    'Page $page of $totalPages',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                IconButton.filledTonal(
                  onPressed: page < totalPages
                      ? () {
                          page++;
                          load();
                        }
                      : null,
                  icon: const Icon(Icons.chevron_right),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class OrderDetailScreen extends StatefulWidget {
  final dynamic id;
  const OrderDetailScreen({super.key, required this.id});
  @override
  State<OrderDetailScreen> createState()=>_OrderDetailScreenState();
}

class _OrderDetailScreenState extends State<OrderDetailScreen> {
  Map<String,dynamic>? order; bool loading=true; bool updating=false; String? error;
  final ScreenshotController screenshotController=ScreenshotController();
  final statuses=<String>['pending','processing','on-hold','completed','cancelled','refunded','failed'];
  @override void initState(){super.initState();load();}
  Future<void> load() async {try{order=Map<String,dynamic>.from(await api.get('/orders/${widget.id}') as Map);error=null;}catch(e){error=e.toString().replaceFirst('Exception: ','');}if(mounted)setState(()=>loading=false);}
  Future<void> updateStatus(String status) async {setState(()=>updating=true);try{await api.patch('/orders/${widget.id}',{'status':status});await load();if(mounted)ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('Order status updated')));}catch(e){if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(e.toString().replaceFirst('Exception: ',''))));}finally{if(mounted)setState(()=>updating=false);}}

  String get symbol {final r=cleanHtml(order?['currency_symbol']??order?['currency']);return r.isEmpty?'£':r;}
  List<dynamic> get lines=>List<dynamic>.from(order?['line_items']??order?['items']??<dynamic>[]);

  Widget invoiceWidget(){final d=order!;return Container(color:Colors.white,padding:const EdgeInsets.all(24),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:<Widget>[
    Row(children:<Widget>[Expanded(child:SvgPicture.asset('assets/pti-logo.svg',height:54,alignment:Alignment.centerLeft)),Column(crossAxisAlignment:CrossAxisAlignment.end,children:<Widget>[Text('INVOICE #${d['number']}',style:const TextStyle(fontSize:20,fontWeight:FontWeight.w900)),Text(cleanHtml(d['date_created']))])]),
    const Divider(height:30),Wrap(spacing:28,runSpacing:14,children:<Widget>[
      SizedBox(width:260,child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:<Widget>[const Text('BILL TO',style:TextStyle(color:kRed,fontWeight:FontWeight.w900)),Text(cleanHtml(d['customer_name']),style:const TextStyle(fontWeight:FontWeight.w700)),Text(cleanHtml(d['billing']?['email'])),Text(cleanHtml(d['billing']?['phone']))])),
      SizedBox(width:260,child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:<Widget>[const Text('ORDER DETAILS',style:TextStyle(color:kRed,fontWeight:FontWeight.w900)),Text('Status: ${cleanHtml(d['status']).toUpperCase()}'),Text('Payment: ${cleanHtml(d['payment_method'])}'),Text('Source: ${cleanHtml(d['source'])}'),if(cleanHtml(d['source_campaign']).isNotEmpty)Text('Campaign: ${cleanHtml(d['source_campaign'])}')]))
    ]),const SizedBox(height:22),
    Container(color:kDark,padding:const EdgeInsets.symmetric(horizontal:12,vertical:10),child:const Row(children:<Widget>[Expanded(flex:5,child:Text('ITEM',style:TextStyle(color:Colors.white,fontWeight:FontWeight.bold))),Expanded(child:Text('QTY',style:TextStyle(color:Colors.white,fontWeight:FontWeight.bold))),Expanded(flex:2,child:Text('TOTAL',textAlign:TextAlign.right,style:TextStyle(color:Colors.white,fontWeight:FontWeight.bold)))])),
    ...lines.map<Widget>((raw){final x=Map<String,dynamic>.from(raw as Map);return Padding(padding:const EdgeInsets.symmetric(horizontal:12,vertical:10),child:Row(children:<Widget>[Expanded(flex:5,child:Text(cleanHtml(x['name']))),Expanded(child:Text('${x['quantity']}')),Expanded(flex:2,child:Text(money(x['total'],symbol),textAlign:TextAlign.right,style:const TextStyle(fontWeight:FontWeight.w700)))]));}),
    const Divider(),Align(alignment:Alignment.centerRight,child:SizedBox(width:290,child:Column(children:<Widget>[SummaryRow(label:'Subtotal',value:money(d['subtotal']??d['total'],symbol)),SummaryRow(label:'Shipping',value:money(d['shipping_total'],symbol)),SummaryRow(label:'Discount',value:money(d['discount_total'],symbol)),const Divider(),SummaryRow(label:'Total',value:money(d['total'],symbol),strong:true)]))),
    const SizedBox(height:25),const Center(child:Text('Pet Trade Innovations • Generated by PTI Premium POS',style:TextStyle(color:Colors.grey,fontSize:12)))
  ]));}

  Future<Uint8List> pdfBytes() async {final d=order!;final doc=pw.Document();final logo=await rootBundle.load('assets/pti-logo.svg');final svg=logo.buffer.asUint8List();doc.addPage(pw.MultiPage(pageFormat:PdfPageFormat.a4,margin:const pw.EdgeInsets.all(28),build:(ctx)=>[pw.Row(mainAxisAlignment:pw.MainAxisAlignment.spaceBetween,children:[pw.SvgImage(svg:utf8.decode(svg),width:180),pw.Column(crossAxisAlignment:pw.CrossAxisAlignment.end,children:[pw.Text('INVOICE #${d['number']}',style:pw.TextStyle(fontSize:18,fontWeight:pw.FontWeight.bold)),pw.Text(cleanHtml(d['date_created']))])]),pw.SizedBox(height:18),pw.Divider(),pw.Row(crossAxisAlignment:pw.CrossAxisAlignment.start,children:[pw.Expanded(child:pw.Column(crossAxisAlignment:pw.CrossAxisAlignment.start,children:[pw.Text('BILL TO',style:pw.TextStyle(fontWeight:pw.FontWeight.bold,color:PdfColor.fromHex('#C9131F'))),pw.Text(cleanHtml(d['customer_name'])),pw.Text(cleanHtml(d['billing']?['email'])),pw.Text(cleanHtml(d['billing']?['phone'])),pw.Text([cleanHtml(d['billing']?['address_1']),cleanHtml(d['billing']?['address_2']),cleanHtml(d['billing']?['city']),cleanHtml(d['billing']?['state']),cleanHtml(d['billing']?['postcode']),cleanHtml(d['billing']?['country'])].where((x)=>x.isNotEmpty).join(', '))])),pw.Expanded(child:pw.Column(crossAxisAlignment:pw.CrossAxisAlignment.start,children:[pw.Text('ORDER DETAILS',style:pw.TextStyle(fontWeight:pw.FontWeight.bold,color:PdfColor.fromHex('#C9131F'))),pw.Text('Status: ${cleanHtml(d['status']).toUpperCase()}'),pw.Text('Payment: ${cleanHtml(d['payment_method'])}')]))]),pw.SizedBox(height:20),pw.Table.fromTextArray(headers:['Item','Qty','Total'],data:lines.map((raw){final x=Map<String,dynamic>.from(raw as Map);return[cleanHtml(x['name']),'${x['quantity']}',money(x['total'],symbol)];}).toList(),headerDecoration:pw.BoxDecoration(color:PdfColor.fromHex('#222222')),headerStyle:pw.TextStyle(color:PdfColors.white,fontWeight:pw.FontWeight.bold)),pw.SizedBox(height:18),pw.Align(alignment:pw.Alignment.centerRight,child:pw.Container(width:220,child:pw.Column(children:[_pdfRow('Subtotal',money(d['subtotal']??d['total'],symbol)),_pdfRow('Shipping',money(d['shipping_total'],symbol)),_pdfRow('Discount',money(d['discount_total'],symbol)),pw.Divider(),_pdfRow('Total',money(d['total'],symbol),bold:true)]))),pw.SizedBox(height:25),pw.Center(child:pw.Text('Pet Trade Innovations • Generated by PTI Premium POS',style:const pw.TextStyle(fontSize:9,color:PdfColors.grey))) ]));return doc.save();}
  pw.Widget _pdfRow(String a,String b,{bool bold=false})=>pw.Padding(padding:const pw.EdgeInsets.symmetric(vertical:4),child:pw.Row(mainAxisAlignment:pw.MainAxisAlignment.spaceBetween,children:[pw.Text(a,style:bold?pw.TextStyle(fontWeight:pw.FontWeight.bold):null),pw.Text(b,style:bold?pw.TextStyle(fontWeight:pw.FontWeight.bold):null)]));
  Future<void> sharePdf() async {await Printing.sharePdf(bytes:await pdfBytes(),filename:'PTI-Invoice-${order!['number']}.pdf');}
  Future<void> shareImage() async {final bytes=await screenshotController.capture(pixelRatio:2.2);if(bytes!=null)await Share.shareXFiles([XFile.fromData(bytes,mimeType:'image/png',name:'PTI-Invoice-${order!['number']}.png')],text:'Invoice #${order!['number']}');}

  @override Widget build(BuildContext context)=>Scaffold(appBar:AppBar(title:Text(order==null?'Order Details':'Order #${order!['number']}'),actions:[PopupMenuButton<String>(onSelected:(v){if(v=='pdf')sharePdf();if(v=='image')shareImage();},itemBuilder:(_)=>const[PopupMenuItem(value:'pdf',child:ListTile(leading:Icon(Icons.picture_as_pdf),title:Text('Share as PDF'))),PopupMenuItem(value:'image',child:ListTile(leading:Icon(Icons.image_outlined),title:Text('Share as Image')))])]),body:loading?const Center(child:CircularProgressIndicator(color:kRed)):error!=null?ErrorPanel(message:error!,retry:load):ListView(padding:const EdgeInsets.all(20),children:<Widget>[
    Card(child:Padding(padding:const EdgeInsets.all(18),child:Column(children:<Widget>[Row(children:<Widget>[Expanded(child:Text('#${order!['number']}',style:Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight:FontWeight.w800))),StatusChip(status:cleanHtml(order!['status']))]),const SizedBox(height:14),DropdownButtonFormField<String>(initialValue:statuses.contains(order!['status'])?order!['status'].toString():statuses.first,decoration:const InputDecoration(labelText:'Order Status',prefixIcon:Icon(Icons.sync_alt)),items:statuses.map((x)=>DropdownMenuItem(value:x,child:Text(x.toUpperCase()))).toList(),onChanged:updating?null:(v){if(v!=null)updateStatus(v);}),if(updating)...[const SizedBox(height:10),const LinearProgressIndicator(color:kRed)] ]))),
    const SizedBox(height:14),SectionCard(title:'Order Attribution',subtitle:'Where this order came from',child:Column(children:[DetailRow(icon:Icons.travel_explore,label:'Source',value:cleanHtml(order!['source'])),DetailRow(icon:Icons.route,label:'Medium',value:cleanHtml(order!['source_medium'])),DetailRow(icon:Icons.campaign_outlined,label:'Campaign',value:cleanHtml(order!['source_campaign']))])),
    const SizedBox(height:14),Screenshot(controller:screenshotController,child:invoiceWidget()),
    const SizedBox(height:14),Row(children:[Expanded(child:FilledButton.icon(onPressed:sharePdf,icon:const Icon(Icons.picture_as_pdf),label:const Text('Share PDF'))),const SizedBox(width:10),Expanded(child:OutlinedButton.icon(onPressed:shareImage,icon:const Icon(Icons.image_outlined),label:const Text('Share Image')))]),
  ]));
}

class ProductsScreen extends StatefulWidget {
  const ProductsScreen({super.key});

  @override
  State<ProductsScreen> createState() => _ProductsScreenState();
}

class _ProductsScreenState extends State<ProductsScreen> {
  final TextEditingController searchController = TextEditingController();
  Timer? debounce;
  List<dynamic> products = <dynamic>[];
  bool loading = true;
  String? error;
  int page = 1;
  int totalPages = 1;

  @override
  void initState() {
    super.initState();
    searchController.addListener(_changed);
    load();
  }

  void _changed() {
    debounce?.cancel();
    debounce = Timer(const Duration(milliseconds: 450), () {
      page = 1;
      load();
    });
    setState(() {});
  }

  @override
  void dispose() {
    debounce?.cancel();
    searchController.dispose();
    super.dispose();
  }

  Future<void> load() async {
    if (mounted) setState(() => loading = true);
    try {
      final result = await api.get('/products', <String, String>{
        'page': '$page',
        'per_page': '20',
        'search': searchController.text.trim(),
      });
      products = List<dynamic>.from(result['items'] ?? <dynamic>[]);
      totalPages = int.tryParse('${result['total_pages'] ?? 1}') ?? 1;
      error = null;
    } catch (e) {
      error = e.toString().replaceFirst('Exception: ', '');
    }
    if (mounted) setState(() => loading = false);
  }

  Future<void> openEditor([Map<String, dynamic>? product]) async {
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => ProductEditorScreen(product: product),
      ),
    );
    load();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
          child: Row(
            children: <Widget>[
              Expanded(
                child: TextField(
                  controller: searchController,
                  decoration: InputDecoration(
                    hintText: 'Search products, SKU...',
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: searchController.text.isNotEmpty
                        ? IconButton(
                            onPressed: searchController.clear,
                            icon: const Icon(Icons.clear),
                          )
                        : null,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              FilledButton.icon(
                onPressed: () => openEditor(),
                style: FilledButton.styleFrom(backgroundColor: kRed),
                icon: const Icon(Icons.add),
                label: const Text('Add Product'),
              ),
              const SizedBox(width: 8),
              IconButton.filledTonal(
                onPressed: load,
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
        ),
        Expanded(
          child: loading
              ? const Center(
                  child: CircularProgressIndicator(color: kRed),
                )
              : error != null
                  ? ErrorPanel(message: error!, retry: load)
                  : LayoutBuilder(
                      builder: (context, constraints) {
                        final columns = constraints.maxWidth >= 1100
                            ? 4
                            : constraints.maxWidth >= 760
                                ? 3
                                : constraints.maxWidth >= 520
                                    ? 2
                                    : 1;

                        return GridView.builder(
                          padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
                          itemCount: products.length,
                          gridDelegate:
                              SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: columns,
                            crossAxisSpacing: 12,
                            mainAxisSpacing: 12,
                            childAspectRatio: columns == 1 ? 2.6 : 0.78,
                          ),
                          itemBuilder: (context, index) {
                            final product = Map<String, dynamic>.from(
                              products[index] as Map,
                            );
                            final imageUrl =
                                product['image']?.toString() ?? '';

                            return Card(
                              child: InkWell(
                                borderRadius: BorderRadius.circular(18),
                                onTap: () => openEditor(product),
                                child: Padding(
                                  padding: const EdgeInsets.all(12),
                                  child: columns == 1
                                      ? Row(
                                          children: <Widget>[
                                            ProductImage(
                                              url: imageUrl,
                                              width: 92,
                                              height: 92,
                                            ),
                                            const SizedBox(width: 14),
                                            Expanded(
                                              child: ProductCardText(
                                                product: product,
                                              ),
                                            ),
                                            const Icon(Icons.chevron_right),
                                          ],
                                        )
                                      : Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: <Widget>[
                                            Expanded(
                                              child: ProductImage(
                                                url: imageUrl,
                                                width: double.infinity,
                                                height: double.infinity,
                                              ),
                                            ),
                                            const SizedBox(height: 10),
                                            ProductCardText(product: product),
                                          ],
                                        ),
                                ),
                              ),
                            );
                          },
                        );
                      },
                    ),
        ),
        if (!loading && error == null && totalPages > 1)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 14),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                IconButton.filledTonal(
                  onPressed: page > 1
                      ? () {
                          page--;
                          load();
                        }
                      : null,
                  icon: const Icon(Icons.chevron_left),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  child: Text(
                    'Page $page of $totalPages',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                IconButton.filledTonal(
                  onPressed: page < totalPages
                      ? () {
                          page++;
                          load();
                        }
                      : null,
                  icon: const Icon(Icons.chevron_right),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class ProductCardText extends StatelessWidget {
  final Map<String, dynamic> product;

  const ProductCardText({
    super.key,
    required this.product,
  });

  @override
  Widget build(BuildContext context) {
    final rawSymbol = cleanHtml(product['currency_symbol']);
    final symbol = rawSymbol.isEmpty ? '£' : rawSymbol;
    final sku = cleanHtml(product['sku']);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          cleanHtml(product['name']),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 4),
        Text(
          'SKU: ${sku.isEmpty ? '—' : sku}',
          style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
        ),
        const SizedBox(height: 6),
        Text(
          money(product['price'], symbol),
          style: const TextStyle(
            color: kRed,
            fontSize: 17,
            fontWeight: FontWeight.w900,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'Stock: ${product['stock_quantity'] ?? 'N/A'}',
          style: TextStyle(color: Colors.grey.shade700, fontSize: 12),
        ),
      ],
    );
  }
}

class ProductImage extends StatelessWidget {
  final String url;
  final double width;
  final double height;

  const ProductImage({
    super.key,
    required this.url,
    required this.width,
    required this.height,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: SizedBox(
        width: width,
        height: height,
        child: url.isEmpty
            ? Container(
                color: Colors.grey.shade100,
                child: const Icon(Icons.inventory_2_outlined, size: 38),
              )
            : CachedNetworkImage(
                imageUrl: url,
                fit: BoxFit.cover,
                placeholder: (_, __) => const Center(
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                errorWidget: (_, __, ___) => Container(
                  color: Colors.grey.shade100,
                  child: const Icon(Icons.inventory_2_outlined, size: 38),
                ),
              ),
      ),
    );
  }
}

class ProductEditorScreen extends StatefulWidget {
  final Map<String, dynamic>? product;

  const ProductEditorScreen({
    super.key,
    this.product,
  });

  @override
  State<ProductEditorScreen> createState() => _ProductEditorScreenState();
}

class _ProductEditorScreenState extends State<ProductEditorScreen> {
  late final TextEditingController nameController;
  late final TextEditingController skuController;
  late final TextEditingController regularPriceController;
  late final TextEditingController salePriceController;
  late final TextEditingController stockController;
  late final TextEditingController descriptionController;
  late final TextEditingController shortDescriptionController;

  bool saving = false;
  bool uploading = false;
  bool manageStock = true;
  String status = 'publish';
  String stockStatus = 'instock';
  String imageUrl = '';
  List<String> gallery = <String>[];

  bool get isNew => widget.product == null;

  @override
  void initState() {
    super.initState();
    final product = widget.product ?? <String, dynamic>{};

    nameController = TextEditingController(
      text: cleanHtml(product['name']),
    );
    skuController = TextEditingController(
      text: cleanHtml(product['sku']),
    );
    regularPriceController = TextEditingController(
      text: product['regular_price']?.toString() ?? '',
    );
    salePriceController = TextEditingController(
      text: product['sale_price']?.toString() ?? '',
    );
    stockController = TextEditingController(
      text: product['stock_quantity']?.toString() ?? '',
    );
    descriptionController = TextEditingController(
      text: cleanHtml(product['description']),
    );
    shortDescriptionController = TextEditingController(
      text: cleanHtml(product['short_description']),
    );

    manageStock = product['manage_stock'] is bool
        ? product['manage_stock'] as bool
        : true;
    status = <String>['publish', 'draft', 'private']
            .contains(product['status']?.toString())
        ? product['status'].toString()
        : 'publish';
    stockStatus = <String>['instock', 'outofstock', 'onbackorder']
            .contains(product['stock_status']?.toString())
        ? product['stock_status'].toString()
        : 'instock';
    imageUrl = product['image']?.toString() ?? '';
    gallery = List<dynamic>.from(product['gallery'] ?? <dynamic>[])
        .map<String>((dynamic item) {
          if (item is Map) return item['src']?.toString() ?? '';
          return item.toString();
        })
        .where((String item) => item.isNotEmpty)
        .toList();
  }

  @override
  void dispose() {
    for (final controller in <TextEditingController>[
      nameController,
      skuController,
      regularPriceController,
      salePriceController,
      stockController,
      descriptionController,
      shortDescriptionController,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<String?> pickUpload() async {
    final picked = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      imageQuality: 88,
    );
    if (picked == null) return null;

    setState(() => uploading = true);
    try {
      final result = await api.uploadMedia(picked);
      return result['source_url']?.toString() ?? result['url']?.toString();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              e.toString().replaceFirst('Exception: ', ''),
            ),
          ),
        );
      }
      return null;
    } finally {
      if (mounted) setState(() => uploading = false);
    }
  }

  Future<void> save() async {
    if (nameController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Product name required')),
      );
      return;
    }

    setState(() => saving = true);
    final body = <String, dynamic>{
      'name': nameController.text.trim(),
      'sku': skuController.text.trim(),
      'regular_price': regularPriceController.text.trim(),
      'sale_price': salePriceController.text.trim(),
      'manage_stock': manageStock,
      'stock_quantity': int.tryParse(stockController.text.trim()),
      'stock_status': stockStatus,
      'status': status,
      'description': descriptionController.text.trim(),
      'short_description': shortDescriptionController.text.trim(),
      'image': imageUrl,
      'gallery': gallery,
    };

    try {
      if (isNew) {
        await api.post('/products', body);
      } else {
        await api.patch('/products/${widget.product!['id']}', body);
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              isNew
                  ? 'Product created successfully'
                  : 'Product updated successfully',
            ),
          ),
        );
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              e.toString().replaceFirst('Exception: ', ''),
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(isNew ? 'Add New Product' : 'Edit Product'),
        actions: <Widget>[
          TextButton.icon(
            onPressed: saving ? null : save,
            icon: saving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.save_outlined),
            label: Text(isNew ? 'Create' : 'Save'),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: <Widget>[
          Card(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                children: <Widget>[
                  ProductImage(
                    url: imageUrl,
                    width: 180,
                    height: 180,
                  ),
                  const SizedBox(height: 14),
                  FilledButton.icon(
                    onPressed: uploading
                        ? null
                        : () async {
                            final uploaded = await pickUpload();
                            if (uploaded != null && mounted) {
                              setState(() => imageUrl = uploaded);
                            }
                          },
                    icon: const Icon(Icons.photo_camera_outlined),
                    label: Text(
                      uploading ? 'Uploading...' : 'Select main image',
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 14),
          SectionCard(
            title: 'Product Information',
            subtitle: 'Same template for new and existing products',
            child: Column(
              children: <Widget>[
                TextField(
                  controller: nameController,
                  decoration: const InputDecoration(
                    labelText: 'Product name',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: skuController,
                  decoration: const InputDecoration(labelText: 'SKU'),
                ),
                const SizedBox(height: 12),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: TextField(
                        controller: regularPriceController,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        decoration: const InputDecoration(
                          labelText: 'Regular price',
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: salePriceController,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        decoration: const InputDecoration(
                          labelText: 'Sale price',
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        value: status,
                        decoration: const InputDecoration(
                          labelText: 'Product status',
                        ),
                        items: <String>['publish', 'draft', 'private']
                            .map(
                              (item) => DropdownMenuItem<String>(
                                value: item,
                                child: Text(item.toUpperCase()),
                              ),
                            )
                            .toList(),
                        onChanged: (value) {
                          if (value != null) setState(() => status = value);
                        },
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        value: stockStatus,
                        decoration: const InputDecoration(
                          labelText: 'Stock status',
                        ),
                        items: <String>[
                          'instock',
                          'outofstock',
                          'onbackorder',
                        ]
                            .map(
                              (item) => DropdownMenuItem<String>(
                                value: item,
                                child: Text(item),
                              ),
                            )
                            .toList(),
                        onChanged: (value) {
                          if (value != null) {
                            setState(() => stockStatus = value);
                          }
                        },
                      ),
                    ),
                  ],
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: manageStock,
                  title: const Text('Manage stock'),
                  onChanged: (value) {
                    setState(() => manageStock = value);
                  },
                ),
                if (manageStock)
                  TextField(
                    controller: stockController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Stock quantity',
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          SectionCard(
            title: 'Descriptions',
            subtitle: 'Short and full description',
            child: Column(
              children: <Widget>[
                TextField(
                  controller: shortDescriptionController,
                  maxLines: 4,
                  decoration: const InputDecoration(
                    labelText: 'Short description',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: descriptionController,
                  maxLines: 8,
                  decoration: const InputDecoration(
                    labelText: 'Description',
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          SectionCard(
            title: 'Gallery',
            subtitle: '${gallery.length} gallery images',
            trailing: IconButton.filledTonal(
              onPressed: uploading
                  ? null
                  : () async {
                      final uploaded = await pickUpload();
                      if (uploaded != null && mounted) {
                        setState(() => gallery.add(uploaded));
                      }
                    },
              icon: const Icon(Icons.add_photo_alternate_outlined),
            ),
            child: gallery.isEmpty
                ? const Padding(
                    padding: EdgeInsets.all(20),
                    child: Center(child: Text('No gallery images')),
                  )
                : Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: List<Widget>.generate(
                      gallery.length,
                      (index) => Stack(
                        children: <Widget>[
                          ProductImage(
                            url: gallery[index],
                            width: 100,
                            height: 100,
                          ),
                          Positioned(
                            right: 3,
                            top: 3,
                            child: IconButton.filled(
                              visualDensity: VisualDensity.compact,
                              onPressed: () {
                                setState(() => gallery.removeAt(index));
                              },
                              icon: const Icon(Icons.close, size: 16),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
          ),
          const SizedBox(height: 24),
          SizedBox(
            height: 52,
            child: FilledButton.icon(
              onPressed: saving ? null : save,
              style: FilledButton.styleFrom(backgroundColor: kRed),
              icon: Icon(
                isNew ? Icons.add_business : Icons.save_outlined,
              ),
              label: Text(
                saving
                    ? 'Saving...'
                    : isNew
                        ? 'Create Product'
                        : 'Save Product',
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class PosScreen extends StatefulWidget {
  const PosScreen({super.key});
  @override
  State<PosScreen> createState() => _PosScreenState();
}

class _PosScreenState extends State<PosScreen> {
  final searchController = TextEditingController();
  final firstNameController = TextEditingController();
  final lastNameController = TextEditingController();
  final emailController = TextEditingController();
  final phoneController = TextEditingController();
  final addressController = TextEditingController();
  final cityController = TextEditingController();
  final postcodeController = TextEditingController();
  final notesController = TextEditingController();
  final Map<int, Map<String, dynamic>> cart = {};
  List<dynamic> products = [];
  List<dynamic> gateways = [];
  bool loading = true;
  bool submitting = false;
  String? error;
  String selectedGateway = 'cod';
  int step = 0;
  int productPage = 1;
  int productTotalPages = 1;

  @override
  void initState() {
    super.initState();
    searchController.addListener(() => setState(() {}));
    loadProducts();
    loadGateways();
  }

  @override
  void dispose() {
    for (final c in [searchController, firstNameController, lastNameController, emailController, phoneController, addressController, cityController, postcodeController, notesController]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> loadProducts({int? page}) async {
    if (page != null) productPage = page;
    setState(() => loading = true);
    try {
      final result = await api.get('/products', {
        'page': '$productPage',
        'per_page': '24',
        'search': searchController.text.trim(),
      });
      products = List<dynamic>.from(result['items'] ?? []);
      productTotalPages = int.tryParse('${result['total_pages'] ?? 1}') ?? 1;
      if (productPage > productTotalPages) productPage = productTotalPages;
      error = null;
    } catch (e) {
      error = e.toString().replaceFirst('Exception: ', '');
    }
    if (mounted) setState(() => loading = false);
  }

  Future<void> loadGateways() async {
    try {
      final result = await api.get('/payment-gateways');
      gateways = List<dynamic>.from(result['items'] ?? result ?? []);
      if (gateways.isNotEmpty && !gateways.any((g) => g['id'] == selectedGateway)) {
        selectedGateway = gateways.first['id'].toString();
      }
      if (mounted) setState(() {});
    } catch (_) {
      gateways = [
        {'id': 'cod', 'title': 'Cash on delivery'},
        {'id': 'bacs', 'title': 'Direct bank transfer'},
      ];
    }
  }

  List<dynamic> get visibleProducts {
    final q = searchController.text.trim().toLowerCase();
    if (q.isEmpty) return products;
    return products.where((raw) {
      final p = Map<String, dynamic>.from(raw as Map);
      return cleanHtml(p['name']).toLowerCase().contains(q) || cleanHtml(p['sku']).toLowerCase().contains(q);
    }).toList();
  }

  void addProduct(Map<String, dynamic> p) {
    final id = int.tryParse('${p['id']}') ?? 0;
    if (id == 0) return;
    if (cart.containsKey(id)) {
      cart[id]!['quantity'] = (cart[id]!['quantity'] as int) + 1;
    } else {
      cart[id] = {
        'product_id': id,
        'name': cleanHtml(p['name']),
        'price': double.tryParse('${p['price']}') ?? 0,
        'quantity': 1,
        'image': p['image']?.toString() ?? '',
      };
    }
    setState(() {});
  }

  double get total => cart.values.fold(0, (sum, x) => sum + (x['price'] as double) * (x['quantity'] as int));

  bool validateCustomer() {
    if (firstNameController.text.trim().isEmpty || phoneController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Customer name aur phone required hain.')));
      return false;
    }
    return true;
  }

  Future<void> completeOrder() async {
    if (cart.isEmpty || !validateCustomer()) return;
    setState(() => submitting = true);
    try {
      final result = await api.post('/orders', {
        'line_items': cart.values.map((x) => {'product_id': x['product_id'], 'quantity': x['quantity']}).toList(),
        'billing': {
          'first_name': firstNameController.text.trim(),
          'last_name': lastNameController.text.trim(),
          'email': emailController.text.trim(),
          'phone': phoneController.text.trim(),
          'address_1': addressController.text.trim(),
          'city': cityController.text.trim(),
          'postcode': postcodeController.text.trim(),
        },
        'payment_method': selectedGateway,
        'customer_note': notesController.text.trim(),
      });
      if (!mounted) return;
      final id = result['id'];
      cart.clear();
      for (final c in [firstNameController,lastNameController,emailController,phoneController,addressController,cityController,postcodeController,notesController]) { c.clear(); }
      setState(() => step = 0);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Order #${result['number'] ?? id} created successfully')));
      if (id != null) {
        await Navigator.push(context, MaterialPageRoute(builder: (_) => OrderDetailScreen(id: id)));
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))));
    } finally {
      if (mounted) setState(() => submitting = false);
    }
  }

  Widget stepHeader() => Padding(
    padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
    child: Row(children: List.generate(3, (i) => Expanded(child: Container(
      margin: EdgeInsets.only(right: i < 2 ? 8 : 0), height: 5,
      decoration: BoxDecoration(color: i <= step ? kRed : Colors.grey.shade300, borderRadius: BorderRadius.circular(10)),
    )))),
  );

  @override
  Widget build(BuildContext context) {
    if (error != null) return ErrorPanel(message: error!, retry: loadProducts);
    return Column(children: [
      stepHeader(),
      Padding(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8), child: Row(children: [
        Expanded(child: Text(['1. Select Products','2. Customer Details','3. Review & Payment'][step], style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800))),
        if (cart.isNotEmpty) Chip(label: Text('${cart.values.fold<int>(0,(s,x)=>s+(x['quantity'] as int))} items')),
      ])),
      Expanded(child: IndexedStack(index: step, children: [productStep(), customerStep(), reviewStep()])),
    ]);
  }

  Widget productStep() => Column(children: [
    Padding(padding: const EdgeInsets.fromLTRB(16, 4, 16, 10), child: TextField(
      controller: searchController,
      onSubmitted: (_) { productPage = 1; loadProducts(); },
      decoration: InputDecoration(hintText: 'Search product name or SKU...', prefixIcon: const Icon(Icons.search), suffixIcon: IconButton(onPressed: () { searchController.clear(); productPage=1; loadProducts(); }, icon: const Icon(Icons.clear))),
    )),
    Expanded(child: loading ? const Center(child: CircularProgressIndicator(color:kRed)) : LayoutBuilder(builder: (context,c) {
      final cols = c.maxWidth >= 1000 ? 4 : c.maxWidth >= 650 ? 3 : c.maxWidth >= 430 ? 2 : 1;
      return GridView.builder(padding: const EdgeInsets.fromLTRB(16,0,16,10), itemCount: visibleProducts.length,
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: cols, crossAxisSpacing: 10, mainAxisSpacing: 10, childAspectRatio: cols==1?2.8:.82),
        itemBuilder: (_,i) { final p=Map<String,dynamic>.from(visibleProducts[i] as Map); final qty=cart[int.tryParse('${p['id']}')??0]?['quantity']??0;
          return Card(child: InkWell(borderRadius: BorderRadius.circular(18), onTap: ()=>addProduct(p), child: Padding(padding: const EdgeInsets.all(10), child: cols==1 ? Row(children:[ProductImage(url:p['image']?.toString()??'',width:80,height:80),const SizedBox(width:10),Expanded(child:ProductCardText(product:p)),Badge(label:Text('$qty'),isLabelVisible:qty>0,child:const Icon(Icons.add_circle,color:kRed))]) : Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Expanded(child:ProductImage(url:p['image']?.toString()??'',width:double.infinity,height:double.infinity)),const SizedBox(height:8),ProductCardText(product:p),if(qty>0) Text('Selected: $qty',style:const TextStyle(color:kRed,fontWeight:FontWeight.w700))]))));
        });
    })),
    pageBar(productPage, productTotalPages, (p)=>loadProducts(page:p)),
    Padding(padding: const EdgeInsets.all(16), child: SizedBox(width:double.infinity,height:52,child:FilledButton.icon(onPressed:cart.isEmpty?null:()=>setState(()=>step=1),style:FilledButton.styleFrom(backgroundColor:kRed),icon:const Icon(Icons.arrow_forward),label:Text('Next • ${money(total)}')))),
  ]);

  Widget customerStep() => ListView(padding: const EdgeInsets.all(16), children: [
    SectionCard(title:'Customer Information',subtitle:'Required for order and invoice',child:Column(children:[
      Row(children:[Expanded(child:TextField(controller:firstNameController,decoration:const InputDecoration(labelText:'First name *'))),const SizedBox(width:12),Expanded(child:TextField(controller:lastNameController,decoration:const InputDecoration(labelText:'Last name')))]),const SizedBox(height:12),
      TextField(controller:phoneController,keyboardType:TextInputType.phone,decoration:const InputDecoration(labelText:'Phone number *',prefixIcon:Icon(Icons.phone_outlined))),const SizedBox(height:12),
      TextField(controller:emailController,keyboardType:TextInputType.emailAddress,decoration:const InputDecoration(labelText:'Email',prefixIcon:Icon(Icons.email_outlined))),const SizedBox(height:12),
      TextField(controller:addressController,decoration:const InputDecoration(labelText:'Address / Location',prefixIcon:Icon(Icons.location_on_outlined))),const SizedBox(height:12),
      Row(children:[Expanded(child:TextField(controller:cityController,decoration:const InputDecoration(labelText:'City'))),const SizedBox(width:12),Expanded(child:TextField(controller:postcodeController,decoration:const InputDecoration(labelText:'Postcode')))]),const SizedBox(height:12),
      TextField(controller:notesController,maxLines:3,decoration:const InputDecoration(labelText:'Order notes')),
    ])),const SizedBox(height:16),
    Row(children:[Expanded(child:OutlinedButton.icon(onPressed:()=>setState(()=>step=0),icon:const Icon(Icons.arrow_back),label:const Text('Back'))),const SizedBox(width:10),Expanded(child:FilledButton.icon(onPressed:(){if(validateCustomer())setState(()=>step=2);},style:FilledButton.styleFrom(backgroundColor:kRed),icon:const Icon(Icons.arrow_forward),label:const Text('Review Order')))]),
  ]);

  Widget reviewStep() => ListView(padding: const EdgeInsets.all(16), children: [
    SectionCard(title:'Order Items',subtitle:'${cart.length} product lines',child:Column(children:cart.values.map((x)=>Card(child:ListTile(
      leading:ProductImage(url:x['image']?.toString()??'',width:52,height:52),title:Text(x['name'],style:const TextStyle(fontWeight:FontWeight.w700)),subtitle:Text(money((x['price'] as double)*(x['quantity'] as int))),
      trailing:Row(mainAxisSize:MainAxisSize.min,children:[IconButton(onPressed:(){final q=x['quantity'] as int;if(q<=1)cart.remove(x['product_id']);else x['quantity']=q-1;setState((){});},icon:const Icon(Icons.remove_circle_outline)),Text('${x['quantity']}',style:const TextStyle(fontWeight:FontWeight.w800)),IconButton(onPressed:(){x['quantity']=(x['quantity'] as int)+1;setState((){});},icon:const Icon(Icons.add_circle_outline))]),
    ))).toList())),const SizedBox(height:14),
    SectionCard(title:'Customer',subtitle:'Invoice recipient',child:Column(children:[DetailRow(icon:Icons.person,label:'Name',value:'${firstNameController.text} ${lastNameController.text}'.trim()),DetailRow(icon:Icons.phone,label:'Phone',value:phoneController.text),DetailRow(icon:Icons.email,label:'Email',value:emailController.text),DetailRow(icon:Icons.location_on,label:'Location',value:[addressController.text,cityController.text,postcodeController.text].where((x)=>x.trim().isNotEmpty).join(', '))])),const SizedBox(height:14),
    SectionCard(title:'Payment Gateway',subtitle:'Select payment method for this order',child:DropdownButtonFormField<String>(value:selectedGateway,items:gateways.map((g)=>DropdownMenuItem<String>(value:g['id'].toString(),child:Text(cleanHtml(g['title'])))).toList(),onChanged:(v)=>setState(()=>selectedGateway=v??selectedGateway),decoration:const InputDecoration(prefixIcon:Icon(Icons.payment),labelText:'Payment method'))),const SizedBox(height:14),
    Card(child:Padding(padding:const EdgeInsets.all(18),child:Row(children:[const Expanded(child:Text('Grand Total',style:TextStyle(fontSize:18,fontWeight:FontWeight.w800))),Text(money(total),style:const TextStyle(fontSize:24,color:kRed,fontWeight:FontWeight.w900))]))),const SizedBox(height:16),
    Row(children:[Expanded(child:OutlinedButton.icon(onPressed:()=>setState(()=>step=1),icon:const Icon(Icons.arrow_back),label:const Text('Back'))),const SizedBox(width:10),Expanded(flex:2,child:FilledButton.icon(onPressed:submitting?null:completeOrder,style:FilledButton.styleFrom(backgroundColor:kRed),icon:submitting?const SizedBox(width:18,height:18,child:CircularProgressIndicator(strokeWidth:2,color:Colors.white)):const Icon(Icons.check_circle),label:Text(submitting?'Creating Order...':'Complete Order')))]),
  ]);

  Widget pageBar(int current,int totalPages,ValueChanged<int> onPage) {
    if (totalPages <= 1) return const SizedBox.shrink();
    return Padding(padding:const EdgeInsets.symmetric(horizontal:16,vertical:8),child:Row(mainAxisAlignment:MainAxisAlignment.center,children:[
      IconButton.filledTonal(onPressed:current>1?()=>onPage(current-1):null,icon:const Icon(Icons.chevron_left)),
      Padding(padding:const EdgeInsets.symmetric(horizontal:14),child:Text('Page $current of $totalPages',style:const TextStyle(fontWeight:FontWeight.w700))),
      IconButton.filledTonal(onPressed:current<totalPages?()=>onPage(current+1):null,icon:const Icon(Icons.chevron_right)),
    ]));
  }
}

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  Future<void> openLink(String url) async {
    await launchUrl(
      Uri.parse(url),
      mode: LaunchMode.externalApplication,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('About App')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: <Widget>[
          Card(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                children: <Widget>[
                  SvgPicture.asset(
                    'assets/pti-logo.svg',
                    height: 74,
                  ),
                  const SizedBox(height: 18),
                  const Text(
                    'Pet Trade Innovations Premium POS',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text('Version 1.0'),
                ],
              ),
            ),
          ),
          const SizedBox(height: 14),
          SectionCard(
            title: 'Developer Information',
            subtitle: 'Application development and support',
            child: Column(
              children: <Widget>[
                const DetailRow(
                  icon: Icons.person_outline,
                  label: 'Author',
                  value: 'Muhammad Khurram Saeed',
                ),
                const DetailRow(
                  icon: Icons.business_outlined,
                  label: 'Company',
                  value: 'W3bco',
                ),
                const DetailRow(
                  icon: Icons.phone_outlined,
                  label: 'Phone',
                  value: '+(92) 303 005 7070',
                ),
                const DetailRow(
                  icon: Icons.email_outlined,
                  label: 'Email',
                  value: 'Ceo@w3bco.com',
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.language),
                  title: const Text(
                    'Website',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  subtitle: const Text('W3bco.com'),
                  trailing: const Icon(Icons.open_in_new),
                  onTap: () => openLink('https://w3bco.com'),
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.work_outline),
                  title: const Text(
                    'Upwork Contract',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  subtitle: const Text('Open Upwork profile'),
                  trailing: const Icon(Icons.open_in_new),
                  onTap: () => openLink(
                    'https://www.upwork.com/freelancers/~01601b3f36feffd4a1',
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          const Center(
            child: Text(
              'Developed by Muhammad Khurram Saeed\n© W3bco • All Rights Reserved',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontWeight: FontWeight.w600,
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class SectionCard extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget child;
  final Widget? trailing;

  const SectionCard({
    super.key,
    required this.title,
    this.subtitle,
    required this.child,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        title,
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      if (subtitle != null) ...<Widget>[
                        const SizedBox(height: 3),
                        Text(
                          subtitle!,
                          style: TextStyle(
                            color: Colors.grey.shade600,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (trailing != null) trailing!,
              ],
            ),
            const SizedBox(height: 14),
            child,
          ],
        ),
      ),
    );
  }
}

class DetailRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const DetailRow({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon),
      title: Text(
        label,
        style: const TextStyle(fontWeight: FontWeight.w700),
      ),
      subtitle: Text(value.isEmpty ? '—' : value),
    );
  }
}

class SummaryRow extends StatelessWidget {
  final String label;
  final String value;
  final bool strong;

  const SummaryRow({
    super.key,
    required this.label,
    required this.value,
    this.strong = false,
  });

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      fontWeight: strong ? FontWeight.w900 : FontWeight.w600,
      fontSize: strong ? 18 : 14,
      color: strong ? kRed : kDark,
    );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        children: <Widget>[
          Expanded(child: Text(label, style: style)),
          Text(value, style: style),
        ],
      ),
    );
  }
}

class StatusChip extends StatelessWidget {
  final String status;

  const StatusChip({
    super.key,
    required this.status,
  });

  @override
  Widget build(BuildContext context) {
    Color color;

    switch (status.toLowerCase()) {
      case 'completed':
        color = Colors.green;
        break;
      case 'processing':
        color = Colors.blue;
        break;
      case 'on-hold':
        color = Colors.orange;
        break;
      case 'cancelled':
      case 'failed':
        color = Colors.red;
        break;
      default:
        color = Colors.grey;
    }

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: 10,
        vertical: 5,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(50),
      ),
      child: Text(
        status.isEmpty ? 'UNKNOWN' : status.toUpperCase(),
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.w800,
          fontSize: 11,
        ),
      ),
    );
  }
}

class ErrorPanel extends StatelessWidget {
  final String message;
  final Future<void> Function() retry;

  const ErrorPanel({
    super.key,
    required this.message,
    required this.retry,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  const Icon(
                    Icons.error_outline,
                    color: kRed,
                    size: 52,
                  ),
                  const SizedBox(height: 14),
                  const Text(
                    'Unable to load data',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    message,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 18),
                  FilledButton.icon(
                    onPressed: retry,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Try Again'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class DeveloperFooter extends StatelessWidget {
  const DeveloperFooter({super.key});

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Text(
        'Developed by Muhammad Khurram Saeed • Version 1.0',
        textAlign: TextAlign.center,
        style: TextStyle(
          fontSize: 12,
          color: Colors.grey,
        ),
      ),
    );
  }
}
