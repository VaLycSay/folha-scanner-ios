package com.nuvio.app.features.player

import android.app.Application
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.test.junit4.createComposeRule
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import kotlin.test.assertEquals

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = Application::class)
class TimelineTouchRegressionTest {
    @get:Rule val compose = createComposeRule()

    @Test fun reportsPressAndReleaseWithoutNeedingASeek() {
        val touching = mutableStateOf(false)
        val events = mutableListOf<Boolean>()
        compose.setContent { ReportTimelineTouch(touching.value) { events += it } }
        compose.runOnIdle { assertEquals(listOf(false), events); touching.value = true }
        compose.runOnIdle { assertEquals(listOf(false, true), events); touching.value = false }
        compose.runOnIdle { assertEquals(listOf(false, true, false), events) }
    }

    @Test fun removingTouchedControlsReleasesTheVisibilityLock() {
        val visible = mutableStateOf(true)
        var touching = false
        compose.setContent { if (visible.value) ReportTimelineTouch(true) { touching = it } }
        compose.runOnIdle { assertEquals(true, touching); visible.value = false }
        compose.runOnIdle { assertEquals(false, touching) }
    }

    @Test fun disposalUsesTheLatestCallback() {
        val visible = mutableStateOf(true)
        val generation = mutableStateOf(1)
        val events = mutableListOf<Pair<Int, Boolean>>()
        compose.setContent {
            val current = generation.value
            if (visible.value) ReportTimelineTouch(true) { events += current to it }
        }
        compose.runOnIdle { generation.value = 2 }
        compose.runOnIdle { visible.value = false }
        compose.runOnIdle { assertEquals(2 to false, events.last()) }
    }
}
