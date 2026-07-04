import 'package:chatdocsflutter/screen/docs_screen.dart';
import 'package:chatdocsflutter/user_authentication/login_signup_screen.dart';
import 'package:chatdocsflutter/user_authentication/user_auth.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<UserAuth>(
      builder: (context, auth, _) {
        return auth.isLoggedIn
            ? const DocumentsScreen()
            : const LoginSignupScreen();
      },
    );
  }
}
