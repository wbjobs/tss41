package com.audiopairing.client

import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.ImageButton
import android.widget.TextView
import androidx.recyclerview.widget.RecyclerView
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

class TrustedDevicesAdapter(
    private var devices: List<TrustedDevice>,
    private val onDeviceClick: (TrustedDevice) -> Unit,
    private val onDeviceRemove: (TrustedDevice) -> Unit
) : RecyclerView.Adapter<TrustedDevicesAdapter.ViewHolder>() {
    
    fun updateDevices(newDevices: List<TrustedDevice>) {
        devices = newDevices
        notifyDataSetChanged()
    }
    
    class ViewHolder(view: View) : RecyclerView.ViewHolder(view) {
        val deviceName: TextView = view.findViewById(R.id.deviceName)
        val deviceInfo: TextView = view.findViewById(R.id.deviceInfo)
        val removeButton: ImageButton = view.findViewById(R.id.removeButton)
    }
    
    override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): ViewHolder {
        val view = LayoutInflater.from(parent.context)
            .inflate(R.layout.item_trusted_device, parent, false)
        return ViewHolder(view)
    }
    
    override fun onBindViewHolder(holder: ViewHolder, position: Int) {
        val device = devices[position]
        
        holder.deviceName.text = device.displayName
        
        val dateFormat = SimpleDateFormat("MMM d, yyyy HH:mm", Locale.getDefault())
        val lastSeen = dateFormat.format(Date(device.lastSeenAt))
        holder.deviceInfo.text = "Paired ${device.pairCount}x • Last seen: $lastSeen"
        
        holder.itemView.setOnClickListener {
            onDeviceClick(device)
        }
        
        holder.removeButton.setOnClickListener {
            onDeviceRemove(device)
        }
    }
    
    override fun getItemCount() = devices.size
}
