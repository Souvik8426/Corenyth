import 'package:flutter/material.dart';
import '../theme/app_colors.dart';

class UserAvatar extends StatelessWidget {
  const UserAvatar({super.key, required this.name, this.size = 48});
  final String name;
  final double size;
  @override
  Widget build(BuildContext context) => ExcludeSemantics(
          child: Container(
        width: size,
        height: size,
        padding: const EdgeInsets.all(1.5),
        decoration: const BoxDecoration(
            shape: BoxShape.circle,
            gradient: SweepGradient(colors: [
              AppColors.coreViolet,
              AppColors.coreCyan,
              AppColors.selectedIcon,
              AppColors.coreViolet
            ])),
        child: Container(
            alignment: Alignment.center,
            decoration: const BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                    center: Alignment(-.4, -.7),
                    colors: [AppColors.avatarLight, AppColors.avatarDark])),
            child: Text(
                name.trim().isEmpty
                    ? 'C'
                    : name.trim().characters.first.toUpperCase(),
                style: TextStyle(
                    fontSize: size * .38,
                    color: AppColors.ivory,
                    fontWeight: FontWeight.w600))),
      ));
}
