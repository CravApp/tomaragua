// =============================================================================
// AQUA TILT - Advanced Water Tracker with Tilt-Reactive Liquid Simulation
// =============================================================================
// Key Technical Pillars:
//  1. sensors_plus → Accelerometer for real-time tilt detection (X/Y axes)
//  2. CustomPainter → Dynamic Path-based liquid drawing with trigonometry
//  3. AnimationController → Smooth drink-level transitions + sine-wave surface
//  4. StatefulWidget → Manages all sensor data, animation states & drink logic
// =============================================================================

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ─── Entry Point ──────────────────────────────────────────────────────────────
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const AquaTiltApp());
}

// ─── App Root ─────────────────────────────────────────────────────────────────
class AquaTiltApp extends StatelessWidget {
  const AquaTiltApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Aqua Tilt',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1E88E5),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const WaterTrackerScreen(),
    );
  }
}

// =============================================================================
// DATA MODEL - Drink Type
// =============================================================================
class DrinkType {
  final String name;
  final Color color;
  final Color surfaceColor;
  final IconData icon;
  final double mlAmount; // milliliters per serving
  final int calories;

  const DrinkType({
    required this.name,
    required this.color,
    required this.surfaceColor,
    required this.icon,
    required this.mlAmount,
    required this.calories,
  });
}

// Predefined drink types matching the reference UI
const List<DrinkType> kDrinkTypes = [
  DrinkType(
    name: 'Water',
    color: Color(0xFF29B6F6),
    surfaceColor: Color(0xFF4FC3F7),
    icon: Icons.water_drop,
    mlAmount: 250,
    calories: 0,
  ),
  DrinkType(
    name: 'Coffee',
    color: Color(0xFF6D4C41),
    surfaceColor: Color(0xFF8D6E63),
    icon: Icons.coffee,
    mlAmount: 150,
    calories: 5,
  ),
  DrinkType(
    name: 'Tea',
    color: Color(0xFF66BB6A),
    surfaceColor: Color(0xFF81C784),
    icon: Icons.emoji_food_beverage,
    mlAmount: 200,
    calories: 2,
  ),
  DrinkType(
    name: 'Juice',
    color: Color(0xFFFF7043),
    surfaceColor: Color(0xFFFF8A65),
    icon: Icons.local_drink,
    mlAmount: 200,
    calories: 90,
  ),
  DrinkType(
    name: 'Milk',
    color: Color(0xFFFFF9C4),
    surfaceColor: Color(0xFFFFFDE7),
    icon: Icons.local_cafe,
    mlAmount: 250,
    calories: 120,
  ),
  DrinkType(
    name: 'Soda',
    color: Color(0xFFAB47BC),
    surfaceColor: Color(0xFFBA68C8),
    icon: Icons.sports_bar,
    mlAmount: 330,
    calories: 140,
  ),
];

// =============================================================================
// MAIN SCREEN - WaterTrackerScreen
// =============================================================================
class WaterTrackerScreen extends StatefulWidget {
  const WaterTrackerScreen({super.key});

  @override
  State<WaterTrackerScreen> createState() => _WaterTrackerScreenState();
}

class _WaterTrackerScreenState extends State<WaterTrackerScreen>
    with TickerProviderStateMixin {
  // ── Navigation ──────────────────────────────────────────────────────────────
  int _selectedTab = 0;

  // ── Drink Tracking State ────────────────────────────────────────────────────
  double _totalIntakeMl = 0;
  final double _dailyGoalMl = 2500;
  DrinkType _selectedDrink = kDrinkTypes[0];
  final List<Map<String, dynamic>> _drinkLog = [];

  // ── Accelerometer State ─────────────────────────────────────────────────────
  // Raw accelerometer value (lateral tilt, used for tilt angle computation)
  // Smoothed tilt angle in radians (low-pass filtered)
  double _tiltAngle = 0.0;
  StreamSubscription<AccelerometerEvent>? _accelSubscription;

  // ── Sensor Settings ─────────────────────────────────────────────────────────
  /// When true the left-right (X) axis is inverted so tilting right makes
  /// the liquid lean left and vice-versa.
  bool _invertX = false;

  /// When true the forward-back (Y) axis contribution is also inverted.
  bool _invertY = false;

  /// Sensitivity multiplier: 0.5 = less reactive, 1.0 = default, 2.0 = very sensitive
  double _sensitivity = 1.0;

  // ── Animation Controllers ───────────────────────────────────────────────────
  // Controls the current water LEVEL (0.0 = empty, 1.0 = full)
  late AnimationController _levelController;
  late Animation<double> _levelAnimation;
  double _currentLevel = 0.0;

  // Controls the sine-wave surface oscillation (infinite loop)
  late AnimationController _waveController;

  // Controls the "drink" button press ripple/bounce
  late AnimationController _drinkButtonController;
  late Animation<double> _drinkButtonScale;

  @override
  void initState() {
    super.initState();
    _initAnimations();
    _loadPersistedData();
    _initAccelerometer();
  }

  // ── Initialize all AnimationControllers ─────────────────────────────────────
  void _initAnimations() {
    // LEVEL ANIMATION: smooth fill/drain transitions (600ms ease-in-out)
    _levelController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _levelAnimation = Tween<double>(begin: 0.0, end: 0.0).animate(
      CurvedAnimation(parent: _levelController, curve: Curves.easeInOut),
    );

    // WAVE ANIMATION: continuous sine-wave oscillation (2 second cycle)
    _waveController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(); // Loops indefinitely

    // DRINK BUTTON: press scale animation for tactile feedback
    _drinkButtonController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 150),
    );
    _drinkButtonScale = Tween<double>(begin: 1.0, end: 0.88).animate(
      CurvedAnimation(parent: _drinkButtonController, curve: Curves.easeInOut),
    );
  }

  // ── Initialize Accelerometer via sensors_plus ────────────────────────────────
  void _initAccelerometer() {
    // For web/desktop preview, sensors_plus may not be available - handle gracefully
    try {
      _accelSubscription = accelerometerEventStream(
        samplingPeriod: const Duration(milliseconds: 50), // 20 Hz update rate
      ).listen(
        (AccelerometerEvent event) {
          if (!mounted) return;
          setState(() {
            // ── TILT MATH ─────────────────────────────────────────────────────
            // Convert X acceleration (-9.8..+9.8 m/s²) to an angle in radians.
            // When the phone tilts right, X goes positive → water tilts right.
            // _invertX flips the sign so right-tilt makes liquid lean left.
            // _sensitivity scales the raw angle for more/less reactive response.
            // We clamp to ±50° (±π/3.6) to avoid extreme distortion.
            //
            // LOW-PASS FILTER: smooth jitter with α = 0.15
            // newAngle = α * rawAngle + (1 - α) * previousAngle
            const double alpha = 0.15;
            // Apply X-axis inversion and sensitivity
            final double xSign = _invertX ? -1.0 : 1.0;
            final double rawAngle =
                xSign * (event.x / 9.8) * (math.pi / 3) * _sensitivity;
            _tiltAngle = alpha * rawAngle + (1 - alpha) * _tiltAngle;
            // Clamp to ±50° to prevent extreme visual distortion
            _tiltAngle = _tiltAngle.clamp(-math.pi / 3.6, math.pi / 3.6);
          });
        },
        onError: (_) {
          // Sensor not available (web/desktop) - tilt stays at 0
          if (kDebugMode) debugPrint('Accelerometer not available');
        },
        cancelOnError: false,
      );
    } catch (e) {
      if (kDebugMode) debugPrint('Sensor init error: $e');
    }
  }

  // ── Persist and Load daily intake + settings ────────────────────────────────
  Future<void> _loadPersistedData() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final today = DateTime.now().toIso8601String().substring(0, 10);
      final savedDate = prefs.getString('date') ?? '';
      if (savedDate == today) {
        final saved = prefs.getDouble('totalIntake') ?? 0.0;
        _animateToLevel(saved);
        setState(() => _totalIntakeMl = saved);
      } else {
        // New day → reset
        await prefs.setString('date', today);
        await prefs.setDouble('totalIntake', 0.0);
      }

      // Load sensor settings
      setState(() {
        _invertX = prefs.getBool('invertX') ?? false;
        _invertY = prefs.getBool('invertY') ?? false;
        _sensitivity = prefs.getDouble('sensitivity') ?? 1.0;
      });
    } catch (_) {}
  }

  Future<void> _persistData() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble('totalIntake', _totalIntakeMl);
    } catch (_) {}
  }

  Future<void> _persistSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('invertX', _invertX);
      await prefs.setBool('invertY', _invertY);
      await prefs.setDouble('sensitivity', _sensitivity);
    } catch (_) {}
  }

  // ── Core Drink Action ───────────────────────────────────────────────────────
  /// Called when user presses the DRINK button.
  /// Adds the selected drink's volume, animates level, logs entry.
  void _drinkWater() async {
    // Button press animation (scale down then up)
    await _drinkButtonController.forward();
    _drinkButtonController.reverse();

    final double addAmount = _selectedDrink.mlAmount;
    final double newTotal = (_totalIntakeMl + addAmount).clamp(0, _dailyGoalMl * 1.5);

    setState(() {
      _totalIntakeMl = newTotal;
      _drinkLog.insert(0, {
        'drink': _selectedDrink,
        'amount': addAmount,
        'time': DateTime.now(),
      });
    });

    _animateToLevel(newTotal);
    _persistData();
  }

  /// Animates the water level from current to a new target based on total intake.
  void _animateToLevel(double totalMl) {
    final double newLevel = (totalMl / _dailyGoalMl).clamp(0.0, 1.0);
    _levelAnimation = Tween<double>(
      begin: _currentLevel,
      end: newLevel,
    ).animate(CurvedAnimation(parent: _levelController, curve: Curves.easeInOut));
    _currentLevel = newLevel;
    _levelController.forward(from: 0.0);
  }

  /// Simulate drinking (level goes DOWN) for the reset/undo action
  void _resetDay() {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF1A2744),
        title: const Text('Reset Day', style: TextStyle(color: Colors.white)),
        content: const Text('Reset your daily water intake to 0?',
            style: TextStyle(color: Colors.white70)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              setState(() {
                _totalIntakeMl = 0;
                _drinkLog.clear();
              });
              _animateToLevel(0);
              _persistData();
            },
            child: const Text('Reset', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _accelSubscription?.cancel();
    _levelController.dispose();
    _waveController.dispose();
    _drinkButtonController.dispose();
    super.dispose();
  }

  // ─────────────────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D1B3E),
      body: SafeArea(
        child: Column(
          children: [
            _buildTopBar(),
            Expanded(child: _buildBody()),
            _buildBottomNav(),
          ],
        ),
      ),
    );
  }

  // ── TOP BAR ─────────────────────────────────────────────────────────────────
  Widget _buildTopBar() {
    final now = DateTime.now();
    final weekdays = ['MON', 'TUE', 'WED', 'THU', 'FRI', 'SAT', 'SUN'];
    final dayName = weekdays[now.weekday - 1];
    final months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0xFF0D1B3E), Color(0xFF1A2E5A)],
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '— TODAY —',
                style: TextStyle(
                  color: Colors.blue.shade300,
                  fontSize: 11,
                  letterSpacing: 3,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                '$dayName, ${months[now.month - 1]} ${now.day}',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1,
                ),
              ),
            ],
          ),
          Row(
            children: [
              // Tilt indicator chip
              AnimatedBuilder(
                animation: _waveController,
                builder: (_, __) {
                  return Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: Colors.blue.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: Colors.blue.withValues(alpha: 0.3)),
                    ),
                    child: Row(
                      children: [
                        Transform.rotate(
                          angle: _tiltAngle * 0.5,
                          child: const Icon(Icons.phone_android,
                              color: Colors.blue, size: 14),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          '${(_tiltAngle * 180 / math.pi).abs().toStringAsFixed(0)}°',
                          style: const TextStyle(color: Colors.blue, fontSize: 12),
                        ),
                        // Show invert indicator when active
                        if (_invertX) ...[
                          const SizedBox(width: 4),
                          const Icon(Icons.swap_horiz, color: Colors.orangeAccent, size: 13),
                        ],
                      ],
                    ),
                  );
                },
              ),
              const SizedBox(width: 8),
              IconButton(
                icon: const Icon(Icons.refresh_rounded, color: Colors.white70),
                onPressed: _resetDay,
                tooltip: 'Reset day',
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ── BODY SWITCHER ───────────────────────────────────────────────────────────
  Widget _buildBody() {
    switch (_selectedTab) {
      case 0:
        return _buildHomeTab();
      case 1:
        return _buildAddDrinkTab();
      case 2:
        return _buildNutritionTab();
      case 3:
        return _buildHistoryTab();
      case 4:
        return _buildSettingsTab();
      default:
        return _buildHomeTab();
    }
  }

  // ─────────────────────────────────────────────────────────────────────────────
  // TAB 0: HOME - The main tilt-reactive glass visualization
  // ─────────────────────────────────────────────────────────────────────────────
  Widget _buildHomeTab() {
    return SingleChildScrollView(
      physics: const NeverScrollableScrollPhysics(),
      child: Column(
        children: [
          const SizedBox(height: 8),
          // ── Progress Header ──────────────────────────────────────────────────
          _buildProgressHeader(),
          const SizedBox(height: 16),
          // ── THE GLASS (CustomPainter + AnimationBuilder) ─────────────────────
          _buildGlassWidget(),
          const SizedBox(height: 20),
          // ── Drink Type Selector ──────────────────────────────────────────────
          _buildDrinkSelector(),
          const SizedBox(height: 16),
          // ── DRINK Button ────────────────────────────────────────────────────
          _buildDrinkButton(),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  Widget _buildProgressHeader() {
    final double pct = (_totalIntakeMl / _dailyGoalMl * 100).clamp(0, 100);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              RichText(
                text: TextSpan(
                  children: [
                    TextSpan(
                      text: '${_totalIntakeMl.toInt()}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 36,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    TextSpan(
                      text: ' of ${_dailyGoalMl.toInt()} ml',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.6),
                        fontSize: 16,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 4),
              Text(
                pct >= 100 ? '🎉 Goal Reached!' : '${pct.toStringAsFixed(0)}% of daily goal',
                style: TextStyle(
                  color: pct >= 100 ? Colors.greenAccent : Colors.blue.shade300,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
          // Circular progress ring
          SizedBox(
            width: 64,
            height: 64,
            child: Stack(
              alignment: Alignment.center,
              children: [
                CircularProgressIndicator(
                  value: pct / 100,
                  strokeWidth: 6,
                  backgroundColor: Colors.white.withValues(alpha: 0.1),
                  valueColor: AlwaysStoppedAnimation<Color>(
                    pct >= 100 ? Colors.greenAccent : const Color(0xFF29B6F6),
                  ),
                ),
                Text(
                  '${pct.toInt()}%',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── THE GLASS WIDGET ─────────────────────────────────────────────────────────
  Widget _buildGlassWidget() {
    return AnimatedBuilder(
      // Listen to both level animation AND wave animation
      animation: Listenable.merge([_levelAnimation, _waveController]),
      builder: (context, _) {
        return SizedBox(
          height: 300,
          child: Center(
            child: CustomPaint(
              size: const Size(200, 280),
              painter: GlassPainter(
                // Current fill level (0.0–1.0), animated smoothly
                fillLevel: _levelAnimation.value,
                // Tilt angle in radians from accelerometer
                tiltAngle: _tiltAngle,
                // Wave animation phase (0.0–1.0 cycling)
                wavePhase: _waveController.value * 2 * math.pi,
                // Color from selected drink type
                liquidColor: _selectedDrink.color,
                liquidSurfaceColor: _selectedDrink.surfaceColor,
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildDrinkSelector() {
    return SizedBox(
      height: 85,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: kDrinkTypes.length,
        itemBuilder: (context, i) {
          final drink = kDrinkTypes[i];
          final bool isSelected = drink == _selectedDrink;
          return GestureDetector(
            onTap: () => setState(() => _selectedDrink = drink),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width: 72,
              margin: const EdgeInsets.symmetric(horizontal: 6),
              decoration: BoxDecoration(
                color: isSelected
                    ? drink.color.withValues(alpha: 0.25)
                    : Colors.white.withValues(alpha: 0.05),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: isSelected ? drink.color : Colors.transparent,
                  width: 2,
                ),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(drink.icon, color: drink.color, size: 28),
                  const SizedBox(height: 4),
                  Text(
                    drink.name,
                    style: TextStyle(
                      color: isSelected ? Colors.white : Colors.white60,
                      fontSize: 11,
                      fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                    ),
                  ),
                  Text(
                    '${drink.mlAmount.toInt()}ml',
                    style: TextStyle(
                      color: isSelected ? drink.color : Colors.white38,
                      fontSize: 10,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildDrinkButton() {
    return ScaleTransition(
      scale: _drinkButtonScale,
      child: GestureDetector(
        onTap: _drinkWater,
        child: Container(
          width: 220,
          height: 56,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                _selectedDrink.color,
                _selectedDrink.color.withValues(alpha: 0.7),
              ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(28),
            boxShadow: [
              BoxShadow(
                color: _selectedDrink.color.withValues(alpha: 0.4),
                blurRadius: 16,
                spreadRadius: 2,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.water_drop, color: Colors.white, size: 22),
              const SizedBox(width: 10),
              Text(
                'DRINK ${_selectedDrink.mlAmount.toInt()} ml',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.2,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────────
  // TAB 1: ADD DRINK - Large glass customizer (inspired by reference UI)
  // ─────────────────────────────────────────────────────────────────────────────
  Widget _buildAddDrinkTab() {
    return Column(
      children: [
        const Padding(
          padding: EdgeInsets.all(20),
          child: Text(
            'CUSTOMIZE YOUR DRINK',
            style: TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.bold,
              letterSpacing: 2,
            ),
          ),
        ),
        Expanded(
          child: Center(
            child: AnimatedBuilder(
              animation: Listenable.merge([_levelAnimation, _waveController]),
              builder: (_, __) => CustomPaint(
                size: const Size(180, 320),
                painter: GlassPainter(
                  fillLevel: _levelAnimation.value,
                  tiltAngle: _tiltAngle,
                  wavePhase: _waveController.value * 2 * math.pi,
                  liquidColor: _selectedDrink.color,
                  liquidSurfaceColor: _selectedDrink.surfaceColor,
                  showMeasurements: true,
                ),
              ),
            ),
          ),
        ),
        // Drink type grid
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: GridView.count(
            crossAxisCount: 3,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            childAspectRatio: 2.5,
            crossAxisSpacing: 8,
            mainAxisSpacing: 8,
            children: kDrinkTypes.map((drink) {
              final bool isSelected = drink == _selectedDrink;
              return GestureDetector(
                onTap: () => setState(() => _selectedDrink = drink),
                child: Container(
                  decoration: BoxDecoration(
                    color: isSelected
                        ? drink.color.withValues(alpha: 0.3)
                        : Colors.white.withValues(alpha: 0.07),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: isSelected ? drink.color : Colors.transparent,
                    ),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(drink.icon, color: drink.color, size: 18),
                      const SizedBox(width: 6),
                      Text(
                        drink.name,
                        style: TextStyle(
                          color: isSelected ? Colors.white : Colors.white60,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }).toList(),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(bottom: 20),
          child: _buildDrinkButton(),
        ),
      ],
    );
  }

  // ─────────────────────────────────────────────────────────────────────────────
  // TAB 2: NUTRITION - Daily breakdown chart
  // ─────────────────────────────────────────────────────────────────────────────
  Widget _buildNutritionTab() {
    final Map<String, double> byDrink = {};
    for (final log in _drinkLog) {
      final name = (log['drink'] as DrinkType).name;
      byDrink[name] = (byDrink[name] ?? 0) + (log['amount'] as double);
    }

    final int totalCalories = _drinkLog.fold(
      0,
      (sum, log) {
        final drink = log['drink'] as DrinkType;
        return sum + (drink.calories * (log['amount'] as double) / 250).round();
      },
    );

    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'NUTRITION',
            style: TextStyle(
              color: Colors.white,
              fontSize: 22,
              fontWeight: FontWeight.bold,
              letterSpacing: 3,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'TODAY ▾',
            style: TextStyle(color: Colors.blue.shade300, fontSize: 14),
          ),
          const SizedBox(height: 24),
          // Calories card
          _nutritionCard(
            label: 'TOTAL CALORIES',
            value: '$totalCalories kcal',
            color: const Color(0xFFFFB23E),
            icon: Icons.local_fire_department,
          ),
          const SizedBox(height: 12),
          _nutritionCard(
            label: 'TOTAL HYDRATION',
            value: '${_totalIntakeMl.toInt()} ml',
            color: const Color(0xFF29B6F6),
            icon: Icons.water_drop,
          ),
          const SizedBox(height: 24),
          const Text(
            'DAILY BREAKDOWN',
            style: TextStyle(color: Colors.white70, fontSize: 13, letterSpacing: 2),
          ),
          const SizedBox(height: 12),
          ...kDrinkTypes.map((drink) {
            final double amount = byDrink[drink.name] ?? 0;
            final double ratio = amount / _dailyGoalMl;
            return Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          Icon(drink.icon, color: drink.color, size: 16),
                          const SizedBox(width: 8),
                          Text(drink.name,
                              style: const TextStyle(color: Colors.white, fontSize: 14)),
                        ],
                      ),
                      Text(
                        '${amount.toInt()} ml',
                        style: TextStyle(color: drink.color, fontSize: 13),
                      ),
                    ],
                  ),
                  const SizedBox(height: 5),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: ratio.clamp(0.0, 1.0),
                      minHeight: 6,
                      backgroundColor: Colors.white.withValues(alpha: 0.08),
                      valueColor: AlwaysStoppedAnimation<Color>(drink.color),
                    ),
                  ),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }

  Widget _nutritionCard({
    required String label,
    required String value,
    required Color color,
    required IconData icon,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.2),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: color, size: 22),
          ),
          const SizedBox(width: 14),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label,
                  style: const TextStyle(color: Colors.white54, fontSize: 11,
                      letterSpacing: 1)),
              Text(value,
                  style: TextStyle(
                      color: color, fontSize: 22, fontWeight: FontWeight.bold)),
            ],
          ),
        ],
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────────
  // TAB 3: HISTORY - Drink log
  // ─────────────────────────────────────────────────────────────────────────────
  Widget _buildHistoryTab() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          child: Row(
            children: [
              const Text('HISTORY',
                  style: TextStyle(color: Colors.white, fontSize: 22,
                      fontWeight: FontWeight.bold, letterSpacing: 3)),
              const Spacer(),
              Container(
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  children: ['WEEK', 'MONTH'].map((label) {
                    return Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                      decoration: BoxDecoration(
                        color: label == 'WEEK' ? const Color(0xFF29B6F6) : Colors.transparent,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(label,
                          style: TextStyle(
                              color: label == 'WEEK' ? Colors.white : Colors.white54,
                              fontSize: 12, fontWeight: FontWeight.bold)),
                    );
                  }).toList(),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: _drinkLog.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.water_drop_outlined,
                          size: 60, color: Colors.white.withValues(alpha: 0.2)),
                      const SizedBox(height: 16),
                      Text('No drinks logged yet',
                          style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.4), fontSize: 16)),
                      const SizedBox(height: 8),
                      Text('Tap DRINK to start tracking!',
                          style: TextStyle(
                              color: Colors.blue.withValues(alpha: 0.6), fontSize: 13)),
                    ],
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: _drinkLog.length,
                  itemBuilder: (context, i) {
                    final entry = _drinkLog[i];
                    final drink = entry['drink'] as DrinkType;
                    final double amount = entry['amount'] as double;
                    final DateTime time = entry['time'] as DateTime;
                    final String timeStr =
                        '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';

                    return Container(
                      margin: const EdgeInsets.only(bottom: 10),
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.05),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                            color: drink.color.withValues(alpha: 0.2)),
                      ),
                      child: Row(
                        children: [
                          Container(
                            width: 44,
                            height: 44,
                            decoration: BoxDecoration(
                              color: drink.color.withValues(alpha: 0.15),
                              shape: BoxShape.circle,
                            ),
                            child: Icon(drink.icon, color: drink.color, size: 22),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(drink.name,
                                    style: const TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.bold,
                                        fontSize: 15)),
                                Text('${amount.toInt()} ml · $timeStr',
                                    style: TextStyle(
                                        color: Colors.white.withValues(alpha: 0.5),
                                        fontSize: 12)),
                              ],
                            ),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 4),
                            decoration: BoxDecoration(
                              color: drink.color.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Text(
                              '+${amount.toInt()}ml',
                              style: TextStyle(
                                  color: drink.color,
                                  fontSize: 13,
                                  fontWeight: FontWeight.bold),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  // ─────────────────────────────────────────────────────────────────────────────
  // TAB 4: SETTINGS - Sensor axis configuration
  // ─────────────────────────────────────────────────────────────────────────────
  Widget _buildSettingsTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Header ────────────────────────────────────────────────────────────
          const Text(
            'SETTINGS',
            style: TextStyle(
              color: Colors.white,
              fontSize: 22,
              fontWeight: FontWeight.bold,
              letterSpacing: 3,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Sensor & display configuration',
            style: TextStyle(color: Colors.blue.shade300, fontSize: 13),
          ),
          const SizedBox(height: 28),

          // ── Section: Sensor Axis ──────────────────────────────────────────────
          _settingsSectionHeader(
            icon: Icons.screen_rotation,
            label: 'SENSOR AXIS',
          ),
          const SizedBox(height: 14),

          // Live tilt preview
          _buildTiltPreview(),
          const SizedBox(height: 16),

          // Invert Left / Right  (X axis)
          _buildSettingsCard(
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.orangeAccent.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(Icons.swap_horiz,
                      color: Colors.orangeAccent, size: 22),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Invert Left / Right',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _invertX
                            ? 'Tilt right → liquid leans LEFT'
                            : 'Tilt right → liquid leans RIGHT',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.5),
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                Switch(
                  value: _invertX,
                  activeColor: Colors.orangeAccent,
                  onChanged: (val) {
                    setState(() => _invertX = val);
                    _persistSettings();
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),

          // Invert Front / Back  (Y axis)
          _buildSettingsCard(
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.purpleAccent.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(Icons.swap_vert,
                      color: Colors.purpleAccent, size: 22),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Invert Front / Back',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _invertY
                            ? 'Y-axis: inverted'
                            : 'Y-axis: default',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.5),
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                Switch(
                  value: _invertY,
                  activeColor: Colors.purpleAccent,
                  onChanged: (val) {
                    setState(() => _invertY = val);
                    _persistSettings();
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 28),

          // ── Section: Sensitivity ──────────────────────────────────────────────
          _settingsSectionHeader(
            icon: Icons.tune,
            label: 'TILT SENSITIVITY',
          ),
          const SizedBox(height: 14),

          _buildSettingsCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.cyanAccent.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Icon(Icons.speed,
                          color: Colors.cyanAccent, size: 22),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Sensor Sensitivity',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            _sensitivityLabel(_sensitivity),
                            style: TextStyle(
                              color: Colors.cyanAccent.withValues(alpha: 0.8),
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Text(
                      '${(_sensitivity * 100).round()}%',
                      style: const TextStyle(
                        color: Colors.cyanAccent,
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                SliderTheme(
                  data: SliderThemeData(
                    activeTrackColor: Colors.cyanAccent,
                    inactiveTrackColor: Colors.white.withValues(alpha: 0.12),
                    thumbColor: Colors.cyanAccent,
                    overlayColor: Colors.cyanAccent.withValues(alpha: 0.15),
                    trackHeight: 4,
                  ),
                  child: Slider(
                    min: 0.25,
                    max: 2.0,
                    divisions: 7,
                    value: _sensitivity,
                    onChanged: (val) {
                      setState(() => _sensitivity = val);
                    },
                    onChangeEnd: (_) => _persistSettings(),
                  ),
                ),
                // Labels
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('Low',
                          style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.4),
                              fontSize: 11)),
                      Text('Default',
                          style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.4),
                              fontSize: 11)),
                      Text('High',
                          style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.4),
                              fontSize: 11)),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 28),

          // ── Reset settings ────────────────────────────────────────────────────
          _settingsSectionHeader(
            icon: Icons.restart_alt,
            label: 'RESET',
          ),
          const SizedBox(height: 14),
          _buildSettingsCard(
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.redAccent.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(Icons.settings_backup_restore,
                      color: Colors.redAccent, size: 22),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Reset Sensor Defaults',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        'Restore axis & sensitivity to factory defaults',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.45),
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                TextButton(
                  onPressed: _resetSensorSettings,
                  style: TextButton.styleFrom(
                    foregroundColor: Colors.redAccent,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                      side: const BorderSide(color: Colors.redAccent),
                    ),
                  ),
                  child: const Text('Reset', style: TextStyle(fontWeight: FontWeight.bold)),
                ),
              ],
            ),
          ),

          const SizedBox(height: 32),

          // ── Info footer ───────────────────────────────────────────────────────
          Center(
            child: Text(
              'Aqua Tilt v1.0 · Sensor settings are saved automatically',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.25),
                fontSize: 11,
              ),
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  /// Live tilt angle preview card shown in Settings
  Widget _buildTiltPreview() {
    return _buildSettingsCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.sensors, color: Colors.blue, size: 18),
              const SizedBox(width: 8),
              const Text(
                'Live Tilt Preview',
                style: TextStyle(
                  color: Colors.white70,
                  fontSize: 13,
                  letterSpacing: 1,
                ),
              ),
              const Spacer(),
              AnimatedBuilder(
                animation: _waveController,
                builder: (_, __) => Text(
                  '${(_tiltAngle * 180 / math.pi).toStringAsFixed(1)}°  '
                  '${_tiltAngle >= 0 ? "→ Right" : "← Left"}',
                  style: const TextStyle(
                    color: Colors.blue,
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          AnimatedBuilder(
            animation: _waveController,
            builder: (_, __) {
              return SizedBox(
                height: 100,
                child: Center(
                  child: CustomPaint(
                    size: const Size(160, 90),
                    painter: GlassPainter(
                      fillLevel: 0.55,
                      tiltAngle: _tiltAngle,
                      wavePhase: _waveController.value * 2 * math.pi,
                      liquidColor: const Color(0xFF29B6F6),
                      liquidSurfaceColor: const Color(0xFF4FC3F7),
                    ),
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 4),
          Center(
            child: Text(
              'Tilt your device to see the effect',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.35),
                fontSize: 11,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Helper: settings section header ─────────────────────────────────────────
  Widget _settingsSectionHeader({
    required IconData icon,
    required String label,
  }) {
    return Row(
      children: [
        Icon(icon, color: Colors.blue.shade300, size: 16),
        const SizedBox(width: 8),
        Text(
          label,
          style: TextStyle(
            color: Colors.blue.shade300,
            fontSize: 12,
            fontWeight: FontWeight.bold,
            letterSpacing: 2,
          ),
        ),
      ],
    );
  }

  // ── Helper: settings card container ─────────────────────────────────────────
  Widget _buildSettingsCard({required Widget child}) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: child,
    );
  }

  // ── Helper: human-readable sensitivity label ─────────────────────────────────
  String _sensitivityLabel(double v) {
    if (v <= 0.4) return 'Very low — barely reacts to tilting';
    if (v <= 0.7) return 'Low — subtle tilt response';
    if (v <= 1.1) return 'Default — natural tilt response';
    if (v <= 1.5) return 'High — very reactive to tilting';
    return 'Maximum — extreme tilt response';
  }

  // ── Reset sensor settings to defaults ───────────────────────────────────────
  void _resetSensorSettings() {
    setState(() {
      _invertX = false;
      _invertY = false;
      _sensitivity = 1.0;
    });
    _persistSettings();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Row(
          children: [
            Icon(Icons.check_circle_outline, color: Colors.white, size: 18),
            SizedBox(width: 10),
            Text('Sensor settings reset to defaults'),
          ],
        ),
        backgroundColor: const Color(0xFF1A3A6B),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  // ── BOTTOM NAVIGATION BAR ───────────────────────────────────────────────────
  Widget _buildBottomNav() {
    final tabs = [
      {'icon': Icons.water_drop, 'label': 'Today'},
      {'icon': Icons.add_circle, 'label': 'Add'},
      {'icon': Icons.bar_chart, 'label': 'Nutrition'},
      {'icon': Icons.history, 'label': 'History'},
      {'icon': Icons.settings, 'label': 'Settings'},
    ];

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF0D1B3E),
        border: Border(
          top: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: tabs.asMap().entries.map((entry) {
          final int index = entry.key;
          final map = entry.value;
          final bool isActive = _selectedTab == index;
          // Highlight Settings tab with a dot when axis is inverted
          final bool hasInvertBadge =
              index == 4 && (_invertX || _invertY);
          return GestureDetector(
            onTap: () => setState(() => _selectedTab = index),
            behavior: HitTestBehavior.opaque,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Stack(
                    clipBehavior: Clip.none,
                    children: [
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          color: isActive
                              ? const Color(0xFF29B6F6).withValues(alpha: 0.15)
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(
                          map['icon'] as IconData,
                          color: isActive ? const Color(0xFF29B6F6) : Colors.white38,
                          size: 24,
                        ),
                      ),
                      // Badge dot when an axis inversion is active
                      if (hasInvertBadge)
                        Positioned(
                          top: -2,
                          right: -2,
                          child: Container(
                            width: 8,
                            height: 8,
                            decoration: const BoxDecoration(
                              color: Colors.orangeAccent,
                              shape: BoxShape.circle,
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    map['label'] as String,
                    style: TextStyle(
                      color: isActive ? const Color(0xFF29B6F6) : Colors.white38,
                      fontSize: 10,
                      fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
                    ),
                  ),
                ],
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}

// =============================================================================
// CUSTOM PAINTER — GlassPainter
// =============================================================================
// This is where ALL the liquid physics magic happens:
//
//  1. Draw the glass outline (trapezoid shape, tapers toward base)
//  2. Compute the TILTED liquid surface using trigonometry
//  3. Apply sine-wave deformation on the surface for wave effect
//  4. Fill the liquid polygon using gradients
//  5. Draw measurement lines (optional)
// =============================================================================
class GlassPainter extends CustomPainter {
  /// Fill level: 0.0 = empty, 1.0 = completely full
  final double fillLevel;

  /// Tilt angle in radians from accelerometer (negative = left, positive = right)
  /// The liquid surface compensation uses: surfaceOffset = -tan(tiltAngle) * halfWidth
  final double tiltAngle;

  /// Wave phase (0..2π), cycled by waveController for oscillating surface
  final double wavePhase;

  /// Base liquid fill color
  final Color liquidColor;

  /// Lighter color for wave crests / surface highlights
  final Color liquidSurfaceColor;

  /// Whether to render measurement marks on the side of the glass
  final bool showMeasurements;

  GlassPainter({
    required this.fillLevel,
    required this.tiltAngle,
    required this.wavePhase,
    required this.liquidColor,
    required this.liquidSurfaceColor,
    this.showMeasurements = false,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final double w = size.width;
    final double h = size.height;

    // ── 1. GLASS GEOMETRY ─────────────────────────────────────────────────────
    // The glass is a trapezoid:
    //   Top edge: full width (w)
    //   Bottom edge: 75% of w, centered
    //   The glass tapers slightly toward the base, like a real drinking glass.

    const double rimPadding = 10.0; // padding from canvas edges at top
    const double bottomInset = 0.12; // how much each side tapers inward (12% of w)

    final double topLeft = rimPadding;
    final double topRight = w - rimPadding;
    final double bottomLeft = w * bottomInset;
    final double bottomRight = w * (1 - bottomInset);
    final double glassTop = rimPadding;
    final double glassBottom = h - rimPadding * 2;

    // Precompute the glass trapezoid as a Path for clipping
    final Path glassPath = Path()
      ..moveTo(topLeft, glassTop)
      ..lineTo(topRight, glassTop)
      ..lineTo(bottomRight, glassBottom)
      ..lineTo(bottomLeft, glassBottom)
      ..close();

    // ── 2. LIQUID SURFACE TILT CALCULATION ───────────────────────────────────
    // When the phone tilts by θ radians, the liquid surface stays horizontal.
    // In our 2D canvas:
    //   • The glass content height = glassBottom - glassTop
    //   • The base fill Y = glassBottom - fillLevel * contentHeight
    //   • The tilt causes one side of the surface to rise and the other to fall.
    //
    // Surface Y at X = baseY - tan(θ) * (X - centerX)
    //
    // We compute Y at the left and right interpolated glass edges at the liquid level.
    //
    // Interpolation: at fill Y, the glass edge X is:
    //   leftX(y) = topLeft + (bottomLeft - topLeft) * t
    //   where t = (y - glassTop) / (glassBottom - glassTop)

    final double contentHeight = glassBottom - glassTop;
    final double baseFillY = glassBottom - fillLevel * contentHeight;
    // centerX = w / 2 (used implicitly via halfWidth)

    // Half-width of glass at the fill level (for tilt offset calculation)
    final double t = (baseFillY - glassTop) / contentHeight;
    final double leftEdgeAtFill = topLeft + (bottomLeft - topLeft) * t;
    final double rightEdgeAtFill = topRight + (bottomRight - topRight) * t;
    final double halfWidth = (rightEdgeAtFill - leftEdgeAtFill) / 2;

    // ── TILT OFFSET ──────────────────────────────────────────────────────────
    // tanθ gives the slope of the tilted surface.
    // Left side: surface rises by +tiltOffset
    // Right side: surface falls by -tiltOffset
    // We cap it so liquid doesn't go outside the glass.
    final double tiltOffset = math.tan(tiltAngle) * halfWidth;
    final double cappedTilt = tiltOffset.clamp(-contentHeight * 0.4, contentHeight * 0.4);

    // Actual Y coordinates of surface at left and right glass edges
    double surfaceLeftY = baseFillY + cappedTilt;  // note: +tilt = tilt right → left rises
    double surfaceRightY = baseFillY - cappedTilt; // right falls

    // Clamp within glass bounds
    surfaceLeftY = surfaceLeftY.clamp(glassTop + 2, glassBottom - 2);
    surfaceRightY = surfaceRightY.clamp(glassTop + 2, glassBottom - 2);

    // ── 3. WAVE SURFACE DEFORMATION ──────────────────────────────────────────
    // We'll sample the surface as a series of X points and add a sine wave.
    // The sine wave creates a gently oscillating ripple effect.
    //
    // surfaceY(x) = linearInterp(surfaceLeftY, surfaceRightY, t) + waveAmp * sin(waveFreq * t + wavePhase)
    //
    // where t = (x - leftEdgeAtFill) / (rightEdgeAtFill - leftEdgeAtFill)

    const int waveSamples = 40; // number of X samples for wave curve
    const double waveAmplitude = 5.0; // pixels of wave height
    const double waveFrequency = 2.0 * math.pi * 2; // 2 full cycles across the glass

    // ── 4. BUILD THE LIQUID POLYGON ──────────────────────────────────────────
    // We build a Path:
    //   - Start at bottomLeft of glass
    //   - Go across the bottom
    //   - Go up right edge to surfaceRightY
    //   - Walk the wavy surface from right to left
    //   - Go down left edge back to bottomLeft
    //   - Close
    //
    // Note: we clip everything inside the glassPath later.

    if (fillLevel > 0.005) {
      final Path liquidPath = Path();

      // Compute left/right glass edges at the bottom
      liquidPath.moveTo(bottomLeft, glassBottom);
      liquidPath.lineTo(bottomRight, glassBottom);

      // Right glass edge: from bottom up to surfaceRightY
      // We interpolate X along the right edge for accuracy
      final double rightEdgeX =
          topRight + (bottomRight - topRight) * (surfaceRightY - glassTop) / contentHeight;
      liquidPath.lineTo(rightEdgeX, surfaceRightY);

      // ── Wave surface from right to left ────────────────────────────────────
      for (int i = waveSamples; i >= 0; i--) {
        final double frac = i / waveSamples; // 1.0 = right, 0.0 = left
        // Linear interpolation of surface Y based on tilt
        final double linearY = surfaceRightY + (surfaceLeftY - surfaceRightY) * (1 - frac);
        // Sine wave: oscillates perpendicular to the tilt slope
        final double waveY = waveAmplitude *
            math.sin(waveFrequency * frac + wavePhase);
        // Corresponding X on the glass (from right edge to left edge at baseFillY)
        final double fracY = baseFillY;
        final double tLocal = (fracY - glassTop) / contentHeight;
        final double leftX = topLeft + (bottomLeft - topLeft) * tLocal;
        final double rightX = topRight + (bottomRight - topRight) * tLocal;
        final double currentX = leftX + (rightX - leftX) * frac;
        liquidPath.lineTo(currentX, linearY + waveY);
      }

      // Left glass edge: from surfaceLeftY down to bottom
      final double leftEdgeX =
          topLeft + (bottomLeft - topLeft) * (surfaceLeftY - glassTop) / contentHeight;
      liquidPath.lineTo(leftEdgeX, surfaceLeftY);
      liquidPath.lineTo(bottomLeft, glassBottom);
      liquidPath.close();

      // ── Clip to the glass shape ────────────────────────────────────────────
      canvas.save();
      canvas.clipPath(glassPath);

      // ── 5. DRAW LIQUID with GRADIENT ─────────────────────────────────────
      // Use a vertical gradient for depth illusion
      final Rect liquidRect = Rect.fromLTWH(0, baseFillY - 20, w, glassBottom - baseFillY + 20);
      final Paint liquidPaint = Paint()
        ..shader = LinearGradient(
          colors: [
            liquidSurfaceColor.withValues(alpha: 0.95),
            liquidColor,
            liquidColor.withValues(alpha: 0.85),
          ],
          stops: const [0.0, 0.3, 1.0],
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        ).createShader(liquidRect)
        ..style = PaintingStyle.fill;

      canvas.drawPath(liquidPath, liquidPaint);

      // ── 6. WAVE SURFACE HIGHLIGHT ─────────────────────────────────────────
      // Draw a lighter strip at the very top of the liquid for the "wet surface" look
      final Paint wavePaint = Paint()
        ..color = liquidSurfaceColor.withValues(alpha: 0.5)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.0
        ..strokeCap = StrokeCap.round;

      final Path waveHighlightPath = Path();
      bool firstPoint = true;
      for (int i = 0; i <= waveSamples; i++) {
        final double frac = i / waveSamples;
        final double linearY = surfaceRightY + (surfaceLeftY - surfaceRightY) * (1 - frac);
        final double waveY = waveAmplitude * math.sin(waveFrequency * frac + wavePhase);
        final double tLocal = (baseFillY - glassTop) / contentHeight;
        final double leftX = topLeft + (bottomLeft - topLeft) * tLocal;
        final double rightX = topRight + (bottomRight - topRight) * tLocal;
        final double currentX = leftX + (rightX - leftX) * frac;
        if (firstPoint) {
          waveHighlightPath.moveTo(currentX, linearY + waveY);
          firstPoint = false;
        } else {
          waveHighlightPath.lineTo(currentX, linearY + waveY);
        }
      }
      canvas.drawPath(waveHighlightPath, wavePaint);

      // ── 7. BUBBLE EFFECT ─────────────────────────────────────────────────
      // Small semi-transparent bubbles rising in the liquid
      if (fillLevel > 0.1) {
        _drawBubbles(canvas, size, glassPath, baseFillY, glassBottom,
            bottomLeft, bottomRight, topLeft, topRight, glassTop, contentHeight);
      }

      canvas.restore();
    }

    // ── 8. DRAW GLASS OUTLINE ────────────────────────────────────────────────
    // Glass rim (top opening)
    final Paint rimPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.8)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.0
      ..strokeCap = StrokeCap.round;

    // Glass body outline
    final Paint glassPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.25)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5;

    canvas.drawPath(glassPath, glassPaint);

    // Rim highlight
    canvas.drawLine(
      Offset(topLeft, glassTop),
      Offset(topRight, glassTop),
      rimPaint,
    );

    // Inner glass reflection / shine (left inner highlight)
    final Paint shinePaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.15)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4.0
      ..strokeCap = StrokeCap.round;

    canvas.drawLine(
      Offset(topLeft + 18, glassTop + 16),
      Offset(bottomLeft + 14, glassBottom - 20),
      shinePaint,
    );

    // ── 9. MEASUREMENT MARKS (optional) ────────────────────────────────────
    if (showMeasurements) {
      _drawMeasurements(canvas, size, topRight, glassTop, glassBottom,
          bottomRight, topLeft, contentHeight);
    }
  }

  /// Draw animated bubble particles inside the liquid
  void _drawBubbles(
    Canvas canvas,
    Size size,
    Path clipPath,
    double baseFillY,
    double glassBottom,
    double bottomLeft,
    double bottomRight,
    double topLeft,
    double topRight,
    double glassTop,
    double contentHeight,
  ) {
    final Paint bubblePaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.18)
      ..style = PaintingStyle.fill;

    // Use wavePhase to animate bubble positions
    final List<_BubbleDef> bubbles = [
      _BubbleDef(0.25, 0.3, 3.0, 1.0),
      _BubbleDef(0.55, 0.6, 2.0, 1.7),
      _BubbleDef(0.7, 0.15, 4.0, 0.5),
      _BubbleDef(0.35, 0.8, 2.5, 2.1),
      _BubbleDef(0.6, 0.45, 1.8, 0.9),
    ];

    canvas.save();
    canvas.clipPath(clipPath);

    for (final b in bubbles) {
      // Bubble rises over time (phase modulated)
      final double phase = (wavePhase / (2 * math.pi) + b.phaseOffset) % 1.0;
      final double liquidHeight = glassBottom - baseFillY;
      if (liquidHeight < 10) continue;

      // X position: interpolated along the glass width at that Y
      final double yPos = glassBottom - phase * liquidHeight;
      final double tLocal = (yPos - glassTop) / contentHeight;
      final double leftX = topLeft + (bottomLeft - topLeft) * tLocal;
      final double rightX = topRight + (bottomRight - topRight) * tLocal;
      final double xPos = leftX + (rightX - leftX) * b.xFrac;

      canvas.drawCircle(Offset(xPos, yPos), b.radius, bubblePaint);
    }

    canvas.restore();
  }

  /// Draw measurement lines (ml marks) on the right side of the glass
  void _drawMeasurements(
    Canvas canvas,
    Size size,
    double topRight,
    double glassTop,
    double glassBottom,
    double bottomRight,
    double topLeft,
    double contentHeight,
  ) {
    final Paint markPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.3)
      ..strokeWidth = 1.0;

    final TextPainter tp = TextPainter(textDirection: TextDirection.ltr);

    // Draw marks at 25%, 50%, 75%, 100%
    for (int i = 1; i <= 4; i++) {
      final double pct = i / 4.0;
      final double y = glassBottom - pct * contentHeight;
      final double t = (y - glassTop) / contentHeight;
      final double rightEdgeX = topRight + (bottomRight - topRight) * t;

      // Horizontal mark line
      canvas.drawLine(
        Offset(rightEdgeX + 2, y),
        Offset(rightEdgeX + 18, y),
        markPaint,
      );

      // Label
      tp.text = TextSpan(
        text: '${(pct * 250).toInt()}ml',
        style: TextStyle(
          color: Colors.white.withValues(alpha: 0.45),
          fontSize: 9,
        ),
      );
      tp.layout();
      tp.paint(canvas, Offset(rightEdgeX + 20, y - tp.height / 2));
    }
  }

  @override
  bool shouldRepaint(GlassPainter oldDelegate) {
    return oldDelegate.fillLevel != fillLevel ||
        oldDelegate.tiltAngle != tiltAngle ||
        oldDelegate.wavePhase != wavePhase ||
        oldDelegate.liquidColor != liquidColor;
  }
}

/// Internal helper for bubble definition
class _BubbleDef {
  final double xFrac; // 0..1 horizontal position in glass
  final double phaseOffset; // stagger bubble rise cycles
  final double radius;
  final double speed; // (unused but kept for extension)

  const _BubbleDef(this.xFrac, this.phaseOffset, this.radius, this.speed);
}
