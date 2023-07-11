package com.adobe.phonegap.push

import android.annotation.SuppressLint
import android.app.Notification
import android.app.NotificationManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log
import androidx.annotation.RequiresApi
import org.json.JSONException
import org.json.JSONObject

/**
 *
 */
@Suppress("HardCodedStringLiteral")
@SuppressLint("LongLogTag")
class PushDismissedHandler : BroadcastReceiver() {
  companion object {
    private const val TAG: String = "${PushPlugin.PREFIX_TAG} (PushDismissedHandler)"
  }

  private val LOG_TAG = "Push_DismissedHandler"

  /**
   * @param context
   * @param intent
   */
  @RequiresApi(Build.VERSION_CODES.M)
  override fun onReceive(context: Context, intent: Intent) {
    if (intent.action == PushConstants.PUSH_DISMISSED) {

      val notID = intent.getIntExtra(PushConstants.NOT_ID, 0)
      val extras = intent.extras
      val fcm = FCMService()

      Log.d(TAG, "not id = $notID")
      Log.d(LOG_TAG, "PushDismissedHandler = $extras");

      // Check if the dismissed item was a single notification or the grouper notification.
      if(notID == PushConstants.GROUP_NOTIFICATION_ID){

        // Since the grouper was dismissed, we need to clear the list of received notifications to be able to display a correct grouper
        // the next time a new batch of notifications are received.
        fcm.cleanNotificationList();
        fcm.cleanCoresNotificationIDList();

      } else {

        // Single notification.

        // When a notification is dismissed by the user, we need to update the list of received notifications:
        // - Remove the content of the notification to indicate it was dismissed.
        fcm.setNotification(notID, "");
        // - Remove this notification from the CORES notification received list.
        try {
          val coresPayloadJsonString = extras!!.getBundle(PushConstants.PUSH_BUNDLE)!!["coresPayload"].toString()
          val jsonCoresPayload = JSONObject(coresPayloadJsonString)
          fcm.removeCoresNotificationIDfromList(jsonCoresPayload.getString("notification_id"))
        } catch (e: JSONException) {
          e.printStackTrace()
        }

        val notificationManager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

        // Check if the notification grouper has enough items to continue in the OS tray, otherwise it should be removed.

        // Check if the notification grouper has enough items to continue in the OS tray, otherwise it should be removed.
        if (fcm.getCoresNotificationIDlist()!!.size === 0) {

          // Remove the grouper notification from the OS tray.
          notificationManager.cancel(PushConstants.GROUP_NOTIFICATION_ID)
        } else {

          // We need to refresh the grouper notification to adjust and display the correct counter of the summary text.
          val activeNotifications = notificationManager.activeNotifications

          // Search the current grouper notification that is displayed in the OS tray.
          for (statusBarNotification in activeNotifications) {
            if (statusBarNotification.id == PushConstants.GROUP_NOTIFICATION_ID) {
              val grouperNotification: Notification = statusBarNotification.notification

              // Refresh the notification grouper to update the summary text (replacing the current notification grouper with a new one but using the same data to
              // avoid losing the notifications that are currently grouped by it).
              if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                fcm.displayGrouperNotification(
                  grouperNotification.extras,
                  context,
                  grouperNotification.getChannelId(),
                  notificationManager
                )
              }
              break
            }

          }

        }

      }

    }

  }
}
