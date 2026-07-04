import 'package:chatdocsflutter/Api_Handling/api_service.dart';
import 'package:chatdocsflutter/provider/provider.dart';
import 'package:chatdocsflutter/screen/home_screen.dart';
import 'package:chatdocsflutter/user_authentication/user_auth.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const supabaseUrl = "YOUR_SUPABASE_URL";
const supabaseAnonKey = "YOUR_SUPABASE_ANON_KEY";

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Supabase.initialize(url: supabaseUrl, anonKey: supabaseAnonKey);
  runApp(const ChatDocsApp());
}

class ChatDocsApp extends StatelessWidget {
  const ChatDocsApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => UserAuth()),
        ProxyProvider<UserAuth, ApiService>(
          update: (context, auth, previous) => previous ?? ApiService(auth),
        ),
        ChangeNotifierProxyProvider<ApiService, DocProvider>(
          create: (context) => DocProvider(context.read<ApiService>()),
          update: (context, api, previous) => previous ?? DocProvider(api),
        ),
      ],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'ChatDocs',
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
          useMaterial3: true,
        ),
        home: const HomeScreen(),
      ),
    );
  }
}
