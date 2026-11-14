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
      bottomNavigationBar: Container(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        decoration: BoxDecoration(
          color: Theme.of(context).cardColor,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.08),
              blurRadius: 10,
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
    );
  }
}
