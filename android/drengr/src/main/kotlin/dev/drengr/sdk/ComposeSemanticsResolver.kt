package dev.drengr.sdk

import android.view.View
import android.view.ViewGroup
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsNode
import androidx.compose.ui.semantics.SemanticsOwner
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import java.lang.reflect.Method

internal data class SemanticsHit(val label: String, val role: String?)

/**
 * Hit-tests the Compose semantics tree at window coordinates. Uses the stable
 * public androidx.compose.ui.semantics surface (SemanticsOwner/Node/Properties);
 * the ONE reflective access is the internal AndroidComposeView.semanticsOwner
 * accessor, version-guarded (any failure → null, never a throw). Compose is
 * compileOnly: this class loads only when compose-ui is present.
 */
internal object ComposeSemanticsResolver {
    private const val OWNER_VIEW = "androidx.compose.ui.platform.AndroidComposeView"
    private const val MAX_LABEL = 256

    @Volatile private var ownerGetter: Method? = null
    @Volatile private var ownerGetterFailed = false

    /** Best labeled semantics node under (x, y), or null. Never throws. */
    fun resolve(root: View, x: Float, y: Float): SemanticsHit? = try {
        val owners = ArrayList<View>(2)
        collectComposeViews(root, owners)
        var hit: SemanticsHit? = null
        for (v in owners) {
            semanticsOwner(v)?.let { o -> hitTest(o, x, y)?.let { hit = it } }
        }
        hit
    } catch (_: Throwable) {
        null
    }

    private fun collectComposeViews(v: View, out: ArrayList<View>) {
        if (isComposeOwner(v)) { out.add(v); return }
        if (v is ViewGroup) {
            for (i in 0 until v.childCount) {
                v.getChildAt(i)?.let { collectComposeViews(it, out) }
            }
        }
    }

    private fun isComposeOwner(v: View): Boolean {
        var c: Class<*>? = v.javaClass
        while (c != null) {
            if (c.name == OWNER_VIEW) return true
            c = c.superclass
        }
        return false
    }

    private fun semanticsOwner(view: View): SemanticsOwner? {
        if (ownerGetterFailed) return null
        val m = ownerGetter ?: try {
            view.javaClass.getMethod("getSemanticsOwner").also { ownerGetter = it }
        } catch (_: Throwable) {
            ownerGetterFailed = true
            return null
        }
        return try { m.invoke(view) as? SemanticsOwner } catch (_: Throwable) { null }
    }

    // BFS so deeper nodes are visited later → deepest labeled node containing the point wins.
    private fun hitTest(owner: SemanticsOwner, x: Float, y: Float): SemanticsHit? {
        val p = Offset(x, y)
        var best: SemanticsHit? = null
        val queue = ArrayDeque<SemanticsNode>()
        queue.addLast(owner.rootSemanticsNode)
        while (queue.isNotEmpty()) {
            val n = queue.removeFirst()
            if (n.boundsInWindow.contains(p)) label(n)?.let { best = it }
            for (c in n.children) queue.addLast(c)
        }
        return best
    }

    private fun label(n: SemanticsNode): SemanticsHit? {
        val c = n.config
        val role = c.getOrNull(SemanticsProperties.Role)?.toString()
        val clickable = c.getOrNull(SemanticsActions.OnClick) != null
        if (!clickable && role == null) return null
        val label = c.getOrNull(SemanticsProperties.ContentDescription)?.firstOrNull()
            ?: c.getOrNull(SemanticsProperties.Text)?.firstOrNull()?.text
            ?: c.getOrNull(SemanticsProperties.TestTag)
            ?: c.getOrNull(SemanticsActions.OnClick)?.label
            ?: role
            ?: return null
        return SemanticsHit(label.take(MAX_LABEL), role)
    }
}
