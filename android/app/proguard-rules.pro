# ML Kit text recognition ships one plugin entry point that names every script
# bundle — Chinese, Devanagari, Japanese, Korean — even when the app depends
# only on Latin. R8 refuses to finish over the missing references, so tell it
# these are deliberately absent. Adding the other bundles instead would put
# tens of megabytes of models we never call into the APK.
-dontwarn com.google.mlkit.vision.text.chinese.**
-dontwarn com.google.mlkit.vision.text.devanagari.**
-dontwarn com.google.mlkit.vision.text.japanese.**
-dontwarn com.google.mlkit.vision.text.korean.**
