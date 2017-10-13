//
//  HCAppleMapService.swift
//  iOSTemplate
//
//  Created by Hypercube1 on 10/9/17.
//  Copyright © 2017 Hypercube. All rights reserved.
//

import Foundation
import MapKit
import HCKalmanFilter
import HCFramework
import HCLocationManager

open class HCAppleMapService: NSObject, MKMapViewDelegate
{
    private static var isRecordingLocation: Bool = false
    open static var useKalmanFilterForTracking : Bool = false
    
    private var pathStrokeColor : UIColor = UIColor.red
    private var pathLineWidth : CGFloat = 5.0
    
    private var lastLocation: CLLocation? = nil
    private var lastTrackingLocation: CLLocation? = nil
    
    private var paths: [[CLLocationCoordinate2D]] = [[CLLocationCoordinate2D]]()
    private var pathLengths: [Float] = []
    private var startTimes: [Date] = []
    private var endTimes: [Date] = []
    
    private var kalmanFilter: HCKalmanAlgorithm?
    private var resetKalmanFilter: Bool = false
    private var isFirstLocation: Bool = true
    
    // Parameters for elimination distortion of initial GPS points when we use HCKalmanFilter
    open static var minTimeForGetPoint = 0.5
    open static var maxTimeForGetPoint = 8.0
    open static var maxAccuracy = 25.0
    open static var minDistance = 0.1
    
    private var lastCorrectPointTime:Date = Date()
    
    open static let sharedService: HCAppleMapService = {
        let instance = HCAppleMapService()
        
        HCAppNotify.observeNotification(instance, selector: #selector(locationUpdated(notification:)), name:"HCLocationUpdated")
        return instance
    }()
    
    // MARK: - Setup Service
    
    /// Set MKMapViewDelegate for mapView
    ///
    /// - Parameter mapView: MKMapView object to which a delegate is set
    open class func setDelegate(onMapView mapView: MKMapView)
    {
        mapView.delegate = HCAppleMapService.sharedService
    }
    
    // MARK: - Map setup and manipulation.
    
    
    /// Set Camera in mapView on specified location (latitude and longitude)
    ///
    /// - Parameters:
    ///   - lat: Camera latitude location
    ///   - long: Camera longitude location
    ///   - animated: Whether the camera is animated. Default value is true
    ///   - mapView:  MKMapView map view
    open class func setCamera(_ lat: CLLocationDegrees, long: CLLocationDegrees, animated: Bool = true, mapView: MKMapView)
    {
        let camera = MKMapCamera()
        camera.centerCoordinate = CLLocationCoordinate2D(latitude: lat, longitude: long)
        
        mapView.setCamera(camera, animated: animated)
    }
    
    ///  Set Camera in mapView on current location
    ///
    /// - Parameters:
    ///   - mapView: MKMapView map view
    ///   - animated: Whether the camera is animated. Default value is true
    open class func setCameraToCurrentLocation(_ mapView: MKMapView, animated: Bool = true)
    {
        let currentLocation = HCLocationManager.sharedManager.getCurrentLocation()
     
        let camera = MKMapCamera()
        camera.centerCoordinate = CLLocationCoordinate2D(latitude: (currentLocation?.coordinate.latitude)!, longitude: (currentLocation?.coordinate.longitude)!)
        
        mapView.setCamera(camera, animated: animated)
    }
    
    // MARK: - Map Markers
    
    /// Create Marker on MKMapView on specified location (latitude and longitude), and specified annotation title
    ///
    /// - Parameters:
    ///   - lat: Marker Latitude
    ///   - long: Marker Longitude
    ///   - mapView: MKMapView map view
    ///   - annotationTitle: Annotation Title string
    open class func createMarker(lat: CLLocationDegrees, long: CLLocationDegrees, mapView: MKMapView, annotationTitle: String)
    {
        let point:MKPointAnnotation = MKPointAnnotation()
        point.coordinate = CLLocationCoordinate2D(latitude: lat, longitude: long)
        point.title = annotationTitle
        
        mapView.addAnnotation(point)
    }
    
    /// Create Marker on MKMapView on current location, and specified annotation title
    ///
    /// - Parameters:
    ///   - mapView: MKMapView map view
    ///   - annotationTitle: Annotation Title string
    open class func createMarkerCurrentPosition(_ mapView: MKMapView, annotationTitle: String)
    {
        let currentLocation = HCLocationManager.sharedManager.getCurrentLocation()
        
        let point:MKPointAnnotation = MKPointAnnotation()
        point.coordinate = CLLocationCoordinate2D(latitude: (currentLocation?.coordinate.latitude)!, longitude: (currentLocation?.coordinate.longitude)!)
        point.title = annotationTitle
        
        mapView.addAnnotation(point)
    }
    
    // MARK: - User Tracking
    
    /// Create and append new path on paths array
    private class func startNewPath()
    {
        sharedService.pathLengths.append(0)
        sharedService.paths.append([CLLocationCoordinate2D]())
    }
    
    /// Append new point to last path in paths array
    ///
    /// - Parameter point: New Point location
    open class func addNewPointToLastPath(point: CLLocationCoordinate2D)
    {
        if var path = sharedService.paths.last {
            path.append(point)
            sharedService.paths[sharedService.paths.count - 1] = path
        }
    }
    
    /// Start Tracking, create new path and start measure path time
    ///
    /// - Parameter isFirstPath: Indicate is this first path during tracking. Default value is false.
    open class func startTracking(_ isFirstPath: Bool = false)
    {
        isRecordingLocation = true
        sharedService.lastCorrectPointTime = Date()
        
        if HCAppleMapService.useKalmanFilterForTracking {
            if sharedService.kalmanFilter != nil {
                sharedService.resetKalmanFilter = true
            }
        }
        
        // Start new path
        startNewPath()
        
        // Add to the last path if needed.
        if let last = sharedService.lastLocation {
            if isFirstPath {
                addNewPointToLastPath(point: last.coordinate) }
        }
        
        // Set current time for this path.
        let currentTime = Date()
        sharedService.startTimes.append(currentTime)
    }
    
    /// Stop Tracking
    open class func endTracking()
    {
        isRecordingLocation = false
        
        let currentTime = Date()
        sharedService.endTimes.append(currentTime)
    }
    
    /// Calculate past time during all tracking paths
    ///
    /// - Returns: Past time during all tracking paths
    open class func getTrackingTime() -> TimeInterval
    {
        var timePassed: TimeInterval = 0
        if sharedService.startTimes.count > 1 && sharedService.endTimes.count > 0 {
            for i in 0...sharedService.startTimes.count - 2 {
                timePassed.add(sharedService.endTimes[i].timeIntervalSince(sharedService.startTimes[i]))
            }
        }
        
        if sharedService.startTimes.count > 0 {
            timePassed.add(Date().timeIntervalSince(sharedService.startTimes.last!)) }
        
        return timePassed
    }
    
    /// Calculate distance during all tracking paths
    ///
    /// - Parameter inMiles: Whether the distance returns in miles. Default value is false.
    /// - Returns: Distance during all tracking paths
    open class func getTrackingDistance(inMiles: Bool = false) -> Float
    {
        var distance: Float = 0
        for num in sharedService.pathLengths {
            distance += num
        }
        
        if inMiles
        {
            distance = distance * 0.621371
        }
        
        return distance
    }
    
    /// Reset all arrays, related to user tracking
    open class func resetAll() {
        sharedService.pathLengths.removeAll()
        sharedService.paths.removeAll()
        sharedService.startTimes.removeAll()
        sharedService.endTimes.removeAll()
    }
    
    // MARK: - Create, Update and Draw polyline on map.
    
    /// Draw One Path Polyline on MapView
    ///
    /// - Parameters:
    ///   - mapView: MKMapView map view
    ///   - path: Array of Locations which make up the path.
    ///   - strokeColor: Paths lines stroke color. Default value is red color.
    ///   - strokeWidth: Paths lines width. Default value is 5.0.
    open class func drawPolyline(_ mapView: MKMapView, path: [CLLocationCoordinate2D], strokeColor: UIColor = UIColor.red, strokeWidth: CGFloat = 5.0)
    {
        let polyline = MKPolyline(coordinates: path, count: path.count)
        HCAppleMapService.sharedService.pathStrokeColor = strokeColor
        HCAppleMapService.sharedService.pathLineWidth = strokeWidth
        
        mapView.add(polyline)
    }
    
    /// Draw All Paths Polylines on MapView
    ///
    /// - Parameters:
    ///   - mapView: MKMapView map view
    ///   - strokeColor: Path line stroke color. Default value is red color.
    ///   - strokeWidth: Path line width. Default value is 5.0.
    open class func drawAllPolylinesOnMap(_ mapView: MKMapView, strokeColor: UIColor = UIColor.red, strokeWidth: CGFloat = 5.0)
    {
        for path in sharedService.paths
        {
            drawPolyline(mapView, path: path, strokeColor: strokeColor)
        }
    }
    
    // MARK: - HCLocationManager Observer Function
    
    /// A function that responds to locationUpdated Notification from HCLocationManager
    func locationUpdated(notification:Notification) {
        
        var myCurrentLocation = notification.object as! CLLocation
        
        lastLocation = myCurrentLocation
        
        // Check if tracking is active
        if HCAppleMapService.isRecordingLocation {
            
            // Check if tracking use Kalman Filter
            if HCAppleMapService.useKalmanFilterForTracking
            {
                if kalmanFilter == nil {
                    
                    // If kalmanFilter is nil, setup kalmanFilter object first
                    self.lastCorrectPointTime = myCurrentLocation.timestamp
                    self.kalmanFilter = HCKalmanAlgorithm(initialLocation: myCurrentLocation)
                    
                    // If horizontalAccuracy of current location is less than maxAccuracy parameter, then add current location to last path locations array. Otherwise reset KalmanFilter.
                    if myCurrentLocation.horizontalAccuracy < HCAppleMapService.maxAccuracy {
                        if var path = paths.last {
                            path[0] = myCurrentLocation.coordinate
                        }
                    } else {
                        self.resetKalmanFilter = true
                    }
                }
                else
                {
                    if let kalmanFilter = self.kalmanFilter
                    {
                        // If necessary reset kalmanFilter object
                        if self.resetKalmanFilter == true
                        {
                            // If horizontalAccuracy of current location is less than maxAccuracy parameter, then reset kalmanFilter object and add current location to last path locations array.
                            if myCurrentLocation.horizontalAccuracy < HCAppleMapService.maxAccuracy
                            {
                                kalmanFilter.resetKalman(newStartLocation: myCurrentLocation)
                                self.resetKalmanFilter = false
                                
                                self.lastCorrectPointTime = myCurrentLocation.timestamp
                                
                                if var path = paths.last {
                                    path[0] = myCurrentLocation.coordinate
                                }
                            }
                            // If reading time of the last correct point exceeds maxTimeForGetPoint parameter, trigger LowAccuracy Notification. Otherwise stop current, and start the next iteration.
                            else if myCurrentLocation.timestamp.timeIntervalSince(self.lastCorrectPointTime) > HCAppleMapService.maxTimeForGetPoint {
                                
                                HCAppNotify.postNotification("HCTriggerLowAccuracy")
                                return
                            } else {
                                return
                            }
                        }
                        else
                        {
                            // If horizontalAccuracy of current location is less than maxAccuracy parameter and reading time of the last correct point exceeds minTimeForGetPoint parameter, process current location with KalmanFilter and add processed location to last path locations array.
                            if myCurrentLocation.horizontalAccuracy < HCAppleMapService.maxAccuracy && myCurrentLocation.timestamp.timeIntervalSince(self.lastCorrectPointTime) > HCAppleMapService.minTimeForGetPoint
                            {
                                let kalmanLocation = kalmanFilter.processState(currentLocation: myCurrentLocation)
                                self.lastCorrectPointTime = myCurrentLocation.timestamp
                                
                                HCAppleMapService.addNewPointToLastPath(point: kalmanLocation.coordinate)
                                
                                myCurrentLocation = kalmanLocation
                            }
                            else
                            {
                                // Otherwise if reading time of the last correct point exceeds maxTimeForGetPoint parameter, trigger LowAccuracy Notification.
                                if myCurrentLocation.timestamp.timeIntervalSince(self.lastCorrectPointTime) > HCAppleMapService.maxTimeForGetPoint
                                {
                                    HCAppNotify.postNotification("HCTriggerLowAccuracy")
                                }
                                
                                return
                            }
                        }
                    }
                }
            }
            else
            {
                // Tracking not use Kalman Filter, then only add current location to last path locations array
                HCAppleMapService.addNewPointToLastPath(point: myCurrentLocation.coordinate)
            }
            
            if lastTrackingLocation != nil {
                
                let distance = myCurrentLocation.distance(from: lastTrackingLocation!)
                
                // If distance from lastTrackingLocation to current location is less then minDistance, return.
                if distance < HCAppleMapService.minDistance
                {
                    return
                }
                
                // Otherwise if tracking is active, add distance to last pathLengths array
                if HCAppleMapService.isRecordingLocation {
                    pathLengths[pathLengths.count - 1] += Float(distance)
                }
            }
            
            // Save current location to lastTrackingLocation
            lastTrackingLocation = myCurrentLocation
        }
        else
        {
            lastTrackingLocation = nil
            lastLocation = myCurrentLocation
        }
    }
    
    // MARK: - MKMapViewDelegate Functions
    
    public func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
        
        let polylineRender = MKPolylineRenderer(overlay: overlay)
        polylineRender.strokeColor = HCAppleMapService.sharedService.pathStrokeColor
        polylineRender.lineWidth = HCAppleMapService.sharedService.pathLineWidth
        polylineRender.lineJoin = .round
        
        return polylineRender
    }
}
