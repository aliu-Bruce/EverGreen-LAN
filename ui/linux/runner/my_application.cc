#include "my_application.h"

#include <flutter_linux/flutter_linux.h>

#include "flutter/generated_plugin_registrant.h"

namespace {

// Minimum window size in logical pixels. Mirrors EgTitleBar's layout budget on
// the Dart side; both must stay in sync.
constexpr int kMinWindowWidth = 960;
constexpr int kMinWindowHeight = 640;

// The custom title bar talks to this channel for buttons, dragging and resizing.
static FlMethodChannel* window_channel = nullptr;

// Reads the pointer position in root coordinates so a drag starts where the
// user pressed, not where the window happens to sit.
void current_pointer_position(gint* root_x, gint* root_y) {
  *root_x = 0;
  *root_y = 0;
  GdkDisplay* display = gdk_display_get_default();
  if (display == nullptr) {
    return;
  }
  GdkSeat* seat = gdk_display_get_default_seat(display);
  if (seat == nullptr) {
    return;
  }
  GdkDevice* pointer = gdk_seat_get_pointer(seat);
  if (pointer == nullptr) {
    return;
  }
  gdk_device_get_position(pointer, nullptr, root_x, root_y);
}

// Dart sends short edge names; GTK wants its own GdkWindowEdge values.
gboolean edge_from_name(const gchar* name, GdkWindowEdge* edge) {
  if (g_str_equal(name, "n")) {
    *edge = GDK_WINDOW_EDGE_NORTH;
  } else if (g_str_equal(name, "s")) {
    *edge = GDK_WINDOW_EDGE_SOUTH;
  } else if (g_str_equal(name, "e")) {
    *edge = GDK_WINDOW_EDGE_EAST;
  } else if (g_str_equal(name, "w")) {
    *edge = GDK_WINDOW_EDGE_WEST;
  } else if (g_str_equal(name, "ne")) {
    *edge = GDK_WINDOW_EDGE_NORTH_EAST;
  } else if (g_str_equal(name, "nw")) {
    *edge = GDK_WINDOW_EDGE_NORTH_WEST;
  } else if (g_str_equal(name, "se")) {
    *edge = GDK_WINDOW_EDGE_SOUTH_EAST;
  } else if (g_str_equal(name, "sw")) {
    *edge = GDK_WINDOW_EDGE_SOUTH_WEST;
  } else {
    return FALSE;
  }
  return TRUE;
}

void window_method_call_cb(FlMethodChannel* channel,
                           FlMethodCall* method_call,
                           gpointer user_data) {
  (void)channel;
  GtkWindow* window = GTK_WINDOW(user_data);
  const gchar* method = fl_method_call_get_name(method_call);
  g_autoptr(GError) error = nullptr;

  if (g_str_equal(method, "minimize")) {
    gtk_window_iconify(window);
    fl_method_call_respond_success(method_call, nullptr, &error);
  } else if (g_str_equal(method, "maximizeToggle")) {
    if (gtk_window_is_maximized(window)) {
      gtk_window_unmaximize(window);
    } else {
      gtk_window_maximize(window);
    }
    fl_method_call_respond_success(method_call, nullptr, &error);
  } else if (g_str_equal(method, "close")) {
    gtk_window_close(window);
    fl_method_call_respond_success(method_call, nullptr, &error);
  } else if (g_str_equal(method, "isMaximized")) {
    g_autoptr(FlValue) result =
        fl_value_new_bool(gtk_window_is_maximized(window));
    fl_method_call_respond_success(method_call, result, &error);
  } else if (g_str_equal(method, "startMove") ||
             g_str_equal(method, "startResize")) {
    gint root_x = 0;
    gint root_y = 0;
    current_pointer_position(&root_x, &root_y);
    GdkWindowEdge edge = GDK_WINDOW_EDGE_NORTH;
    gboolean known = TRUE;
    if (g_str_equal(method, "startResize")) {
      FlValue* args = fl_method_call_get_args(method_call);
      known = args != nullptr &&
              fl_value_get_type(args) == FL_VALUE_TYPE_STRING &&
              edge_from_name(fl_value_get_string(args), &edge);
    }
    if (!known) {
      fl_method_call_respond_error(method_call, "bad_edge",
                                   "unknown resize edge", nullptr, &error);
    } else {
      // gtk_get_current_event_time() yields the newest input timestamp; when
      // the channel call is too far from an event it falls back to 0, which
      // GDK treats as GDK_CURRENT_TIME. Wayland uses the seat's grab serial.
      const guint32 timestamp = gtk_get_current_event_time();
      if (g_str_equal(method, "startMove")) {
        gtk_window_begin_move_drag(window, 1, root_x, root_y, timestamp);
      } else {
        gtk_window_begin_resize_drag(window, edge, 1, root_x, root_y,
                                     timestamp);
      }
      fl_method_call_respond_success(method_call, nullptr, &error);
    }
  } else {
    fl_method_call_respond_not_implemented(method_call, &error);
  }

  if (error != nullptr) {
    g_warning("Failed to respond to window method call: %s", error->message);
  }
}

void window_destroyed_cb(GtkWidget* widget, gpointer user_data) {
  (void)widget;
  (void)user_data;
  if (window_channel != nullptr) {
    fl_method_channel_set_method_call_handler(window_channel, nullptr, nullptr,
                                              nullptr);
  }
}

void setup_window_channel(GtkWindow* window, FlView* view) {
  FlBinaryMessenger* messenger =
      fl_engine_get_binary_messenger(fl_view_get_engine(view));
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  window_channel = fl_method_channel_new(messenger, "eglan/window",
                                         FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(window_channel,
                                            window_method_call_cb, window,
                                            nullptr);
  g_signal_connect(window, "destroy", G_CALLBACK(window_destroyed_cb), nullptr);
}

}  // namespace

// Called when first Flutter frame received.
static void first_frame_cb(MyApplication* self, FlView* view) {
  gtk_widget_show(gtk_widget_get_toplevel(GTK_WIDGET(view)));
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);

  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));
  gtk_window_set_default_size(window, 1280, 720);

  // Undecorated: Flutter draws the whole window. The window manager still owns
  // stacking and snapping; the custom title bar owns the look.
  gtk_window_set_decorated(window, FALSE);
  GdkGeometry geometry = {};
  geometry.min_width = kMinWindowWidth;
  geometry.min_height = kMinWindowHeight;
  gtk_window_set_geometry_hints(window, nullptr, &geometry, GDK_HINT_MIN_SIZE);

  gtk_window_set_title(window, "EverGreen LAN");

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(
      project, self->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);
  GdkRGBA background_color;
  // Background defaults to black, override it here if necessary, e.g. #00000000
  // for transparent.
  gdk_rgba_parse(&background_color, "#000000");
  fl_view_set_background_color(view, &background_color);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  // Show the window when Flutter renders.
  // Requires the view to be realized so we can start rendering.
  g_signal_connect_swapped(view, "first-frame", G_CALLBACK(first_frame_cb),
                           self);
  gtk_widget_realize(GTK_WIDGET(view));

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));
  setup_window_channel(window, view);

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// Implements GApplication::local_command_line.
static gboolean my_application_local_command_line(GApplication* application,
                                                   gchar*** arguments,
                                                   int* exit_status) {
  MyApplication* self = MY_APPLICATION(application);
  // Strip out the first argument as it is the binary name.
  self->dart_entrypoint_arguments = g_strdupv(*arguments + 1);

  g_autoptr(GError) error = nullptr;
  if (!g_application_register(application, nullptr, &error)) {
    g_warning("Failed to register: %s", error->message);
    *exit_status = 1;
    return TRUE;
  }

  g_application_activate(application);
  *exit_status = 0;

  return TRUE;
}

// Implements GApplication::startup.
static void my_application_startup(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application startup.

  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication* application) {
  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->local_command_line =
      my_application_local_command_line;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {}

MyApplication* my_application_new() {
  // Set the program name to the application ID, which helps various systems
  // like GTK and desktop environments map this running application to its
  // corresponding .desktop file. This ensures better integration by allowing
  // the application to be recognized beyond its binary name.
  g_set_prgname(APPLICATION_ID);

  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                      "application-id", APPLICATION_ID, "flags",
                                      G_APPLICATION_NON_UNIQUE, nullptr));
}
