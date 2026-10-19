# R8/ProGuard rules for the Android release build.
#
# Flutter turns R8 minification on for release builds, so anything that is only
# reached through reflection or through lookups *by name* has to be kept here.
#
# ``shared_preferences_android`` 2.5.0, ``path_provider_android`` and anything
# else built on ``package:jni`` call their Kotlin code through JNI. Those JNI
# bindings resolve the Kotlin runtime classes by name, so R8 renaming them
# rewrites the descriptor of the methods the Dart side calls, and the app dies
# before ``runApp()`` -- the first frame never renders, which the user sees as a
# black screen that never goes away:
#
#     java.lang.NoSuchMethodError: no non-static method
#     "...SharedPreferencesApiRegistrar;.getAll(...Lkotlin/coroutines/Continuation;)..."
#
# Upstream report: https://github.com/flutter/flutter/issues/194649
# These are the keep rules recommended there. They are also what the plugins are
# expected to ship as consumer rules, so they can be dropped once ``jni`` keeps
# the six classes itself (https://github.com/dart-lang/native/issues/3732).

-keep class kotlin.Unit { *; }
-keep class kotlin.Result { *; }
-keep class kotlin.Result$Failure { *; }
-keep class kotlin.coroutines.Continuation { *; }
-keep class kotlin.coroutines.intrinsics.CoroutineSingletons { *; }
-keep class kotlin.coroutines.intrinsics.IntrinsicsKt { *; }
