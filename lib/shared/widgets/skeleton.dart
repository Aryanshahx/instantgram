import 'package:flutter/material.dart';

/// Grey shapes with a soft moving light, shown while content loads.
/// Used instead of loading circles.

const Color _base = Color(0xFF1D2029);
const Color _light = Color(0xFF2C303B);

/// What the loading content will look like.
enum SkeletonKind {
  /// rows with a round picture and two lines (people, chats, settings)
  list,

  /// feed posts: header, big square picture, buttons, lines
  post,

  /// 3 columns of squares (profile grid, explore)
  grid,

  /// one full screen clip with name and lines at the bottom
  clip,

  /// chat bubbles left and right
  chat,

  /// comments: small round picture and lines
  comments,

  /// songs: square cover and two lines
  tracks,

  /// profile: big round picture, numbers, grid
  profile,
}

/// Moves a soft light over its child. Children paint their shapes with any
/// solid colour; the light only shows on top of painted pixels.
class Shimmer extends StatefulWidget {
  const Shimmer({super.key, required this.child});
  final Widget child;

  @override
  State<Shimmer> createState() => _ShimmerState();
}

class _ShimmerState extends State<Shimmer> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1300),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (still) {
      _c.stop();
    } else if (!_c.isAnimating) {
      _c.repeat();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _c,
    child: widget.child,
    builder: (context, child) => ShaderMask(
      blendMode: BlendMode.srcATop,
      shaderCallback: (rect) => LinearGradient(
        begin: const Alignment(-1, -0.25),
        end: const Alignment(1, 0.25),
        colors: const [_base, _light, _base],
        stops: const [0.3, 0.5, 0.7],
        transform: _Slide(_c.value * 2.4 - 1.2),
      ).createShader(rect),
      child: child,
    ),
  );
}

class _Slide extends GradientTransform {
  const _Slide(this.p);
  final double p;

  @override
  Matrix4? transform(Rect bounds, {TextDirection? textDirection}) =>
      Matrix4.translationValues(bounds.width * p, 0, 0);
}

/// One grey shape.
class SkeletonBox extends StatelessWidget {
  const SkeletonBox({
    super.key,
    this.width,
    this.height = 12,
    this.radius = 8,
    this.circle = false,
  });
  final double? width;
  final double height;
  final double radius;
  final bool circle;

  @override
  Widget build(BuildContext context) => Container(
    width: circle ? height : width,
    height: height,
    decoration: BoxDecoration(
      color: _base,
      shape: circle ? BoxShape.circle : BoxShape.rectangle,
      borderRadius: circle ? null : BorderRadius.circular(radius),
    ),
  );
}

/// A ready made loading layout. Works inside lists, slivers and full pages.
class Skeleton extends StatelessWidget {
  const Skeleton({super.key, this.kind = SkeletonKind.list, this.count});
  final SkeletonKind kind;

  /// how many rows / items (a good default per kind when null)
  final int? count;

  @override
  Widget build(BuildContext context) {
    final body = switch (kind) {
      SkeletonKind.list => _rows(count ?? 8, 48),
      SkeletonKind.comments => _rows(count ?? 6, 34),
      SkeletonKind.tracks => _tracks(count ?? 7),
      SkeletonKind.post => _posts(count ?? 2),
      SkeletonKind.grid => _grid(count ?? 4),
      SkeletonKind.clip => _clip(),
      SkeletonKind.chat => _chat(count ?? 8),
      SkeletonKind.profile => _profile(),
    };
    return Semantics(
      label: 'Loading',
      child: ExcludeSemantics(
        child: SingleChildScrollView(
          primary: false,
          physics: const NeverScrollableScrollPhysics(),
          child: Shimmer(child: body),
        ),
      ),
    );
  }

  static Widget _rows(int n, double pic) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < n; i++)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              children: [
                SkeletonBox(height: pic, circle: true),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      FractionallySizedBox(
                        widthFactor: i.isEven ? 0.45 : 0.6,
                        child: const SkeletonBox(height: 12),
                      ),
                      const SizedBox(height: 8),
                      FractionallySizedBox(
                        widthFactor: i.isEven ? 0.75 : 0.55,
                        child: const SkeletonBox(height: 10),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    ),
  );

  static Widget _tracks(int n) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < n; i++)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 7),
            child: Row(
              children: [
                const SkeletonBox(width: 48, height: 48, radius: 10),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      FractionallySizedBox(
                        widthFactor: i.isEven ? 0.55 : 0.7,
                        child: const SkeletonBox(height: 12),
                      ),
                      const SizedBox(height: 8),
                      const FractionallySizedBox(
                        widthFactor: 0.35,
                        child: SkeletonBox(height: 10),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                const SkeletonBox(width: 28, height: 28, circle: true),
              ],
            ),
          ),
      ],
    ),
  );

  static Widget _posts(int n) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      for (var i = 0; i < n; i++)
        Padding(
          padding: const EdgeInsets.only(bottom: 18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(14, 10, 14, 10),
                child: Row(
                  children: [
                    SkeletonBox(height: 36, circle: true),
                    SizedBox(width: 10),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SkeletonBox(width: 110, height: 11),
                        SizedBox(height: 6),
                        SkeletonBox(width: 70, height: 9),
                      ],
                    ),
                  ],
                ),
              ),
              const AspectRatio(
                aspectRatio: 1,
                child: SkeletonBox(radius: 0, height: double.infinity),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Row(
                      children: [
                        SkeletonBox(height: 24, circle: true),
                        SizedBox(width: 14),
                        SkeletonBox(height: 24, circle: true),
                        SizedBox(width: 14),
                        SkeletonBox(height: 24, circle: true),
                      ],
                    ),
                    const SizedBox(height: 12),
                    FractionallySizedBox(
                      widthFactor: i.isEven ? 0.7 : 0.5,
                      child: const SkeletonBox(height: 11),
                    ),
                    const SizedBox(height: 7),
                    const FractionallySizedBox(
                      widthFactor: 0.4,
                      child: SkeletonBox(height: 10),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
    ],
  );

  static Widget _grid(int rows) => Padding(
    padding: const EdgeInsets.all(2),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var r = 0; r < rows; r++)
          Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: Row(
              children: [
                for (var c = 0; c < 3; c++) ...[
                  if (c > 0) const SizedBox(width: 2),
                  const Expanded(
                    child: AspectRatio(
                      aspectRatio: 0.8,
                      child: SkeletonBox(radius: 4, height: double.infinity),
                    ),
                  ),
                ],
              ],
            ),
          ),
      ],
    ),
  );

  static Widget _clip() => LayoutBuilder(
    builder: (context, box) {
      final h = box.hasBoundedHeight && box.maxHeight.isFinite
          ? box.maxHeight
          : MediaQuery.sizeOf(context).height;
      return SizedBox(
        height: h,
        child: const Stack(
          children: [
            Positioned(
              left: 16,
              right: 90,
              bottom: 40,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      SkeletonBox(height: 34, circle: true),
                      SizedBox(width: 10),
                      SkeletonBox(width: 120, height: 12),
                    ],
                  ),
                  SizedBox(height: 12),
                  SkeletonBox(width: 220, height: 11),
                  SizedBox(height: 8),
                  SkeletonBox(width: 150, height: 10),
                ],
              ),
            ),
            Positioned(
              right: 18,
              bottom: 50,
              child: Column(
                children: [
                  SkeletonBox(height: 30, circle: true),
                  SizedBox(height: 22),
                  SkeletonBox(height: 30, circle: true),
                  SizedBox(height: 22),
                  SkeletonBox(height: 30, circle: true),
                ],
              ),
            ),
          ],
        ),
      );
    },
  );

  static Widget _chat(int n) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < n; i++)
          Align(
            alignment: i % 3 == 1
                ? Alignment.centerRight
                : Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: SkeletonBox(
                width: 90.0 + (i * 37) % 130,
                height: i % 4 == 2 ? 54 : 36,
                radius: 16,
              ),
            ),
          ),
      ],
    ),
  );

  static Widget _profile() => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      const Padding(
        padding: EdgeInsets.fromLTRB(16, 18, 16, 14),
        child: Row(
          children: [
            SkeletonBox(height: 80, circle: true),
            SizedBox(width: 18),
            Expanded(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [_Stat(), _Stat(), _Stat()],
              ),
            ),
          ],
        ),
      ),
      const Padding(
        padding: EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SkeletonBox(width: 140, height: 12),
            SizedBox(height: 8),
            SkeletonBox(width: 220, height: 10),
            SizedBox(height: 14),
            SkeletonBox(width: double.infinity, height: 34, radius: 12),
          ],
        ),
      ),
      _grid(3),
    ],
  );
}

class _Stat extends StatelessWidget {
  const _Stat();

  @override
  Widget build(BuildContext context) => const Column(
    children: [
      SkeletonBox(width: 30, height: 14),
      SizedBox(height: 6),
      SkeletonBox(width: 46, height: 9),
    ],
  );
}

/// Fills all the space with one grey shape and a moving light
/// (picture or video still loading, nothing to show yet).
class ShimmerFill extends StatelessWidget {
  const ShimmerFill({super.key, this.radius = 0});
  final double radius;

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Loading',
    child: Shimmer(
      child: SizedBox.expand(
        child: SkeletonBox(radius: radius, height: double.infinity),
      ),
    ),
  );
}

/// A soft light that moves over what is already shown (for example a
/// clip's cover picture while the video loads). Does not hide the content.
class LoadingSweep extends StatefulWidget {
  const LoadingSweep({super.key});

  @override
  State<LoadingSweep> createState() => _LoadingSweepState();
}

class _LoadingSweepState extends State<LoadingSweep>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (still) {
      _c.stop();
    } else if (!_c.isAnimating) {
      _c.repeat();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: Semantics(
      label: 'Loading',
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) => DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: const Alignment(-1, -0.4),
              end: const Alignment(1, 0.4),
              colors: const [
                Color(0x00FFFFFF),
                Color(0x1FFFFFFF),
                Color(0x00FFFFFF),
              ],
              stops: const [0.35, 0.5, 0.65],
              transform: _Slide(_c.value * 2.4 - 1.2),
            ),
          ),
          child: const SizedBox.expand(),
        ),
      ),
    ),
  );
}
