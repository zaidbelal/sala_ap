import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import '../../../../../core/constants/app_colors.dart';
import '../../../../../core/widgets/app_map.dart';

class LocationPickerScreen extends StatefulWidget {
  const LocationPickerScreen({super.key});

  @override
  State<LocationPickerScreen> createState() => _LocationPickerScreenState();
}

class _LocationPickerScreenState extends State<LocationPickerScreen> {
  LatLng? _selectedLocation;

  @override
  Widget build(BuildContext context) {
    const fallbackCenter = LatLng(15.3694, 44.1910);
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'تحديد موقع التوصيل',
          style: TextStyle(
            fontFamily: 'Cairo',
            fontWeight: FontWeight.w800,
          ),
        ),
        centerTitle: true,
      ),
      body: AppMap(
        initialLocation: null,
        defaultCenter: fallbackCenter,
        initialZoom: 16.5,
        title: 'موقع التوصيل',
        markerLabel: 'موقع بقالتي',
        allowPick: true,
        showSearch: true,
        showCurrentLocation: true,
        style: AppMapStyle.terrain,
        onLocationChanged: (location) {
          setState(() => _selectedLocation = location);
        },
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        maintainBottomViewPadding: true,
        child: Container(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
          decoration: BoxDecoration(
            color: Theme.of(context).cardColor,
            border: Border(
              top: BorderSide(
                  color: Theme.of(context).dividerColor.withValues(alpha: 0.1)),
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.06),
                blurRadius: 12,
                offset: const Offset(0, -3),
              ),
            ],
          ),
          child: SizedBox(
            height: 52,
            child: ElevatedButton.icon(
              onPressed: _selectedLocation == null
                  ? null
                  : () => Navigator.of(context).pop(_selectedLocation),
              icon: const Icon(Icons.check_circle_rounded, color: Colors.white),
              label: Text(
                _selectedLocation == null
                    ? 'انقر على موقع بقالتك في الخريطة لتحديده'
                    : 'تأكيد موقع التوصيل ✅',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontFamily: 'Cairo',
                  fontWeight: FontWeight.w800,
                  fontSize: 14,
                  color: Colors.white,
                ),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: Colors.white,
                disabledBackgroundColor: Colors.grey.shade400,
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
