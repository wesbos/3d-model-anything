# Debug builds are not minified. If release minification is turned on, keep the
# serializers kotlinx.serialization generates for the bundle format.
-keepattributes *Annotation*, InnerClasses
-keepclassmembers class com.wesbos.housecapture.bundle.** {
    *** Companion;
    kotlinx.serialization.KSerializer serializer(...);
}
-keep class com.google.ar.core.** { *; }
