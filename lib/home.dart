import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'dashboard.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  final _displayNameController = TextEditingController();
  
  bool _isUnlocked = false; // false = Sign In (Locked), true = Sign Up (Unlocked)
  bool _obscurePassword = true;
  bool _obscureConfirmPassword = true;
  bool _isLoading = false;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    _displayNameController.dispose();
    super.dispose();
  }

  void _onLockToggled(bool isUnlocked) {
    setState(() {
      _isUnlocked = isUnlocked;
    });
  }

  void _handleSubmit() async {
    final email = _emailController.text.trim();
    final password = _passwordController.text;
    final isLogin = !_isUnlocked;

    if (email.isEmpty || password.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter email and password')),
      );
      return;
    }

    if (!isLogin) {
      if (_confirmPasswordController.text != password) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Passwords do not match')),
        );
        return;
      }
      if (password.length < 6) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Password must be at least 6 characters')),
        );
        return;
      }
    }

    setState(() => _isLoading = true);
    try {
      final auth = FirebaseAuth.instance;
      UserCredential cred;
      if (isLogin) {
        cred = await auth.signInWithEmailAndPassword(
            email: email, password: password);
      } else {
        cred = await auth.createUserWithEmailAndPassword(
            email: email, password: password);
      }
      final firebaseUser = cred.user;
      if (firebaseUser == null) throw Exception('Firebase returned no user.');
      User user = firebaseUser;
      final userEmail = user.email ?? email;

      // Resolve display name: typed name > Auth displayName > email prefix.
      // On sign-up we save it to FirebaseAuth so it persists across devices.
      final typedName = _displayNameController.text.trim();
      final emailPrefix = userEmail.contains('@')
          ? userEmail.split('@').first
          : userEmail;
      if (!isLogin) {
        final authDisplay = (user.displayName ?? '').trim();
        final chosenName = typedName.isNotEmpty
            ? typedName
            : (authDisplay.isNotEmpty ? authDisplay : emailPrefix);
        if (user.displayName != chosenName) {
          try {
            await user.updateDisplayName(chosenName);
            await user.reload();
            user = auth.currentUser ?? user;
          } catch (_) {
            // Non-fatal: Firestore doc below still gets the right name.
          }
        }
      }

      // Automatically create / update the user doc in Firestore.
      // Best-effort: login must succeed even if Firestore rules/network fail.
      // IMPORTANT: for existing users we only fill MISSING displayName/email
      // so we never overwrite a name the user set in Profile.
      try {
        final userRef =
            FirebaseFirestore.instance.collection('users').doc(user.uid);
        final now = FieldValue.serverTimestamp();
        final snap = await userRef.get();
        final existing = snap.data() ?? {};
        final existingName = (existing['displayName'] as String?)?.trim() ?? '';
        final existingEmail = (existing['email'] as String?)?.trim() ?? '';

        final authName = (user.displayName ?? '').trim();
        // Sign-up typed name wins, then Auth name, then existing, then prefix.
        final resolvedName = !isLogin
            ? (typedName.isNotEmpty
                ? typedName
                : (authName.isNotEmpty ? authName : emailPrefix))
            : (existingName.isNotEmpty
                ? existingName
                : (authName.isNotEmpty ? authName : emailPrefix));

        final patch = <String, dynamic>{
          'lastLoginAt': now,
          'isOnline': true,
          'lastSeen': now,
        };
        if (existingEmail.isEmpty && userEmail.isNotEmpty) {
          patch['email'] = userEmail;
        }
        if (existingName.isEmpty && resolvedName.isNotEmpty) {
          patch['displayName'] = resolvedName;
        }
        if (!snap.exists) {
          patch['email'] = userEmail;
          patch['displayName'] = resolvedName;
          patch['createdAt'] = now;
        }
        await userRef.set(patch, SetOptions(merge: true));
      } catch (firestoreError) {
        // Don't block login — most common cause is firestore.rules not deployed.
        debugPrint('User doc write failed (login still continues): $firestoreError');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
                content: Text(
                    'Signed in, but profile sync failed. Deploy firestore.rules.')),
          );
        }
      }

      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (context) => DashboardScreen(email: userEmail),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      String msg = e.toString();
      if (e is FirebaseAuthException) {
        switch (e.code) {
          case 'user-not-found':
            msg = 'No account found for $email. Tap lock to Sign Up first.';
            break;
          case 'wrong-password':
          case 'invalid-credential':
            msg = 'Wrong email or password. Try again.';
            break;
          case 'invalid-email':
            msg = 'That email address is invalid.';
            break;
          case 'user-disabled':
            msg = 'This account has been disabled.';
            break;
          case 'email-already-in-use':
            msg = 'Email already registered. Switch to Sign In.';
            break;
          case 'network-request-failed':
            msg = 'Network error. Check internet and try again.';
            break;
        }
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg)),
      );
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool isLogin = !_isUnlocked;

    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color(0xFF0F172A), // Deep Slate / Dark Navy
              Color(0xFF090D16), // Darker Near Black
              Color(0xFF020617), // Pure Dark Environment
            ],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24.0),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // Animated Lock Logo controls Sign In / Sign Up
                  AnimatedLockLogo(
                    isUnlocked: _isUnlocked,
                    onToggle: _onLockToggled,
                  ),
                  const SizedBox(height: 24),
                  // Title
                  const Text(
                    'LockDown',
                    style: TextStyle(
                      fontSize: 32,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                      letterSpacing: 1.5,
                    ),
                  ),
                  const SizedBox(height: 8),
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 300),
                    child: Text(
                      isLogin ? 'Tap lock to unlock Sign Up' : 'Unlocked: Create your account',
                      key: ValueKey<bool>(isLogin),
                      style: TextStyle(
                        fontSize: 15,
                        color: isLogin ? Colors.grey[400] : Colors.greenAccent.withValues(alpha: 0.8),
                        letterSpacing: 0.5,
                      ),
                    ),
                  ),
                  const SizedBox(height: 40),

                  // Animated Form Container that appears/switches based on lock state
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 400),
                    transitionBuilder: (child, animation) {
                      return FadeTransition(
                        opacity: animation,
                        child: SlideTransition(
                          position: Tween<Offset>(
                            begin: const Offset(0.0, 0.08),
                            end: Offset.zero,
                          ).animate(CurvedAnimation(parent: animation, curve: Curves.easeInOut)),
                          child: child,
                        ),
                      );
                    },
                    child: Column(
                      key: ValueKey<bool>(isLogin),
                      children: [
                        // Display Name (Sign Up only) — this is what room
                        // members will see instead of "User ab12".
                        if (!isLogin) ...[
                          TextField(
                            controller: _displayNameController,
                            textCapitalization: TextCapitalization.words,
                            style: const TextStyle(color: Colors.white),
                            decoration: InputDecoration(
                              labelText: 'Display Name (e.g. John)',
                              labelStyle: TextStyle(color: Colors.grey[400]),
                              prefixIcon: const Icon(Icons.badge_outlined,
                                  color: Colors.cyanAccent),
                              filled: true,
                              fillColor: Colors.white.withValues(alpha: 0.05),
                              enabledBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(16),
                                borderSide: BorderSide(
                                    color: Colors.white.withValues(alpha: 0.1)),
                              ),
                              focusedBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(16),
                                borderSide: const BorderSide(
                                    color: Colors.cyanAccent, width: 2),
                              ),
                            ),
                          ),
                          const SizedBox(height: 16),
                        ],
                        // Email / Username Input Field
                        TextField(
                          controller: _emailController,
                          style: const TextStyle(color: Colors.white),
                          decoration: InputDecoration(
                            labelText: 'Email or Username',
                            labelStyle: TextStyle(color: Colors.grey[400]),
                            prefixIcon: const Icon(Icons.person_outline, color: Colors.cyanAccent),
                            filled: true,
                            fillColor: Colors.white.withValues(alpha: 0.05),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(16),
                              borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(16),
                              borderSide: const BorderSide(color: Colors.cyanAccent, width: 2),
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),

                        // Password Input Field
                        TextField(
                          controller: _passwordController,
                          obscureText: _obscurePassword,
                          style: const TextStyle(color: Colors.white),
                          decoration: InputDecoration(
                            labelText: 'Password',
                            labelStyle: TextStyle(color: Colors.grey[400]),
                            prefixIcon: const Icon(Icons.lock_outline, color: Colors.cyanAccent),
                            suffixIcon: IconButton(
                              icon: Icon(
                                _obscurePassword ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                                color: Colors.grey[400],
                              ),
                              onPressed: () {
                                setState(() {
                                  _obscurePassword = !_obscurePassword;
                                });
                              },
                            ),
                            filled: true,
                            fillColor: Colors.white.withValues(alpha: 0.05),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(16),
                              borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(16),
                              borderSide: const BorderSide(color: Colors.cyanAccent, width: 2),
                            ),
                          ),
                        ),

                        // Confirm Password Field (only shown when Unlocked / Sign Up)
                        if (!isLogin) ...[
                          const SizedBox(height: 16),
                          TextField(
                            controller: _confirmPasswordController,
                            obscureText: _obscureConfirmPassword,
                            style: const TextStyle(color: Colors.white),
                            decoration: InputDecoration(
                              labelText: 'Confirm Password',
                              labelStyle: TextStyle(color: Colors.grey[400]),
                              prefixIcon: const Icon(Icons.lock_reset, color: Colors.cyanAccent),
                              suffixIcon: IconButton(
                                icon: Icon(
                                  _obscureConfirmPassword ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                                  color: Colors.grey[400],
                                ),
                                onPressed: () {
                                  setState(() {
                                    _obscureConfirmPassword = !_obscureConfirmPassword;
                                  });
                                },
                              ),
                              filled: true,
                              fillColor: Colors.white.withValues(alpha: 0.05),
                              enabledBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(16),
                                borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
                              ),
                              focusedBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(16),
                                borderSide: const BorderSide(color: Colors.cyanAccent, width: 2),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),

                  const SizedBox(height: 32),

                  // Action Button (Sign In / Create Account)
                  SizedBox(
                    width: double.infinity,
                    height: 56,
                    child: ElevatedButton(
                      onPressed: _isLoading ? null : _handleSubmit,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: isLogin ? const Color(0xFF3B82F6) : Colors.green[700],
                        foregroundColor: Colors.white,
                        elevation: 8,
                        shadowColor: (isLogin ? Colors.blueAccent : Colors.greenAccent).withValues(alpha: 0.5),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          if (_isLoading)
                            const SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white),
                            )
                          else
                            Icon(
                                isLogin
                                    ? Icons.login_rounded
                                    : Icons.person_add_rounded,
                                size: 22),
                          const SizedBox(width: 12),
                          Text(
                            _isLoading
                                ? 'Please wait...'
                                : (isLogin ? 'Sign In' : 'Create Account'),
                            style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w600,
                              letterSpacing: 0.5,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),

                  // Hint text guiding the user
                  Text(
                    isLogin ? '🔒 Tap the lock above to switch to Sign Up' : '🔓 Tap the lock above to switch to Sign In',
                    style: TextStyle(color: Colors.grey[500], fontSize: 13),
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

class AnimatedLockLogo extends StatefulWidget {
  final bool isUnlocked;
  final ValueChanged<bool> onToggle;

  const AnimatedLockLogo({
    super.key,
    required this.isUnlocked,
    required this.onToggle,
  });

  @override
  State<AnimatedLockLogo> createState() => _AnimatedLockLogoState();
}

class _AnimatedLockLogoState extends State<AnimatedLockLogo> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _scaleAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 350),
      vsync: this,
    );
    _scaleAnimation = Tween<double>(begin: 1.0, end: 1.25).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        widget.onToggle(!widget.isUnlocked);
        _controller.forward().then((_) => _controller.reverse());
      },
      child: ScaleTransition(
        scale: _scaleAnimation,
        child: Container(
          padding: const EdgeInsets.all(22),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.white.withValues(alpha: 0.05),
            boxShadow: [
              BoxShadow(
                color: (widget.isUnlocked ? Colors.greenAccent : Colors.blueAccent).withValues(alpha: 0.25),
                blurRadius: 35,
                spreadRadius: 10,
              ),
            ],
          ),
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 300),
            transitionBuilder: (child, animation) => ScaleTransition(scale: animation, child: child),
            child: Icon(
              widget.isUnlocked ? Icons.lock_open_rounded : Icons.lock_outline_rounded,
              key: ValueKey<bool>(widget.isUnlocked),
              size: 60,
              color: widget.isUnlocked ? Colors.greenAccent : Colors.cyanAccent,
            ),
          ),
        ),
      ),
    );
  }
}
