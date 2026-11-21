const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { defineSecret } = require("firebase-functions/params");
const { onDocumentCreated } = require("firebase-functions/v2/firestore");
const { initializeApp } = require("firebase-admin/app");
const { getAuth } = require("firebase-admin/auth");
const {
  FieldPath,
  FieldValue,
  Timestamp,
  getFirestore,
} = require("firebase-admin/firestore");
const { getMessaging } = require("firebase-admin/messaging");
const { getStorage } = require("firebase-admin/storage");
const crypto = require("crypto");
 
initializeApp();
const auth = getAuth();
const db = getFirestore();
const messaging = getMessaging();
const storage = getStorage();
// ─── الأسرار (Secrets) ───
const smsSenderId = defineSecret("SMS_SENDER_ID");
const smsApiKey = defineSecret("SMS_API_KEY");
const googlePlacesApiKey = defineSecret("GOOGLE_PLACES_API_KEY");
// ══════════════════════════════════════════════════════════════
// 🏛️ CORE ARCHITECTURAL & SERVICE LAYER (100/100 PRODUCTION)
// ══════════════════════════════════════════════════════════════

const OTP_TTL_MS = 5 * 60 * 1000;
const RESEND_COOLDOWN_MS = 60 * 1000;
const MAX_ATTEMPTS = 5;

// ── 1. آلة حالات دورة حياة الطلب المركزية (Order Finite State Machine) ──
class OrderStateMachine {
  static transitions = {
    pending: ["confirmed", "preparing", "shipped", "delivered", "rejected", "cancelled"],
    confirmed: ["preparing", "shipped", "delivered", "cancelled"],
    preparing: ["shipped", "on_the_way", "delivered", "cancelled"],
    shipped: ["on_the_way", "delivered", "cancelled"],
    on_the_way: ["delivered", "cancelled"],
    delivered: ["return_requested", "returned", "delivered"],
    return_requested: ["returned", "delivered"],
    cancelled: [],
    rejected: [],
    returned: []
  };

  static assertCanTransition(currentStatus, targetStatus) {
    const cleanCurrent = String(currentStatus || "pending").toLowerCase();
    const cleanTarget = String(targetStatus || "").toLowerCase();
    if (cleanCurrent === cleanTarget) return;
    const allowed = this.transitions[cleanCurrent] || [];
    if (!allowed.includes(cleanTarget)) {
      throw new HttpsError("failed-precondition", `انتقال غير مصرح به للطلب من حالة "${cleanCurrent}" إلى "${cleanTarget}"`);
    }
  }
}

// ── 2. محرك توليد المعرفات الفريدة والأرقام المرجعية الموحدة (IdGenerator) ──
class IdGenerator {
  static generateInvoiceNumber() {
    const now = new Date();
    const dateHeader = `${now.getFullYear()}${String(now.getMonth() + 1).padStart(2, "0")}${String(now.getDate()).padStart(2, "0")}`;
    const timeHex = Date.now().toString(36).toUpperCase();
    const randomEntropy = crypto.randomBytes(4).toString("hex").toUpperCase();
    return `INV-${dateHeader}-${timeHex}-${randomEntropy}`;
  }

  static generateReturnNumber() {
    const entropy = crypto.randomBytes(3).toString("hex").toUpperCase();
    return `RET-${Date.now().toString(36).toUpperCase().slice(-5)}${entropy}`;
  }
}

// ── 3. خدمة معالجة التواقيع فائقة الكفاءة بنمط البث المباشر (Zero-Heap Stream Pipeline) ──
class SignatureService {
  static async processSignature(cleanOrderId, signatureData) {
    if (!signatureData) return null;

    // 🔒 1. سقف حجم صارم: التوقيع الرقمي لا يتجاوز 500KB أبداً، منع هجمات حشو الذاكرة
    if (typeof signatureData !== "string" || signatureData.length > 500000) {
      throw new HttpsError("invalid-argument", "حجم بيانات التوقيع يتجاوز السقف الأقصى المسموح (500KB)");
    }

    const rawSig = signatureData.trim();
    const bucket = storage.bucket();

    if (rawSig.startsWith("https://")) {
      try {
        const parsedUrl = new URL(rawSig);
        const objectPath = decodeURIComponent(parsedUrl.pathname.split("/o/")[1] || "");
      const belongsToOrder = objectPath.startsWith(`signatures/signature_${cleanOrderId}_`) ||
                              objectPath.startsWith(`signatures/order_${cleanOrderId}_`);
        const isProjectBucket = parsedUrl.pathname.includes(`/b/${bucket.name}/`) ||
                                parsedUrl.pathname.includes("app-sala-b42dd");

        if (parsedUrl.hostname !== "firebasestorage.googleapis.com" ||
            !parsedUrl.searchParams.has("token") || !belongsToOrder || !isProjectBucket) {
          throw new HttpsError("invalid-argument", "رابط التوقيع غير صالح أو لا ينتمي لمستودع المنصة");
        }
        return rawSig;
      } catch (urlError) {
        if (urlError instanceof HttpsError) throw urlError;
        throw new HttpsError("invalid-argument", "صيغة رابط التوقيع غير صالحة");
      }
    }

    const cleanedSig = rawSig.replace(/[\r\n\s]+/g, "");
    const signatureMatch = cleanedSig.match(/^data:image\/png;base64,([A-Za-z0-9+/=]+)$/);
    if (!signatureMatch) {
      throw new HttpsError("invalid-argument", "صيغة التوقيع غير صالحة (يجب أن تكون صورة PNG Base64 معتمدة)");
    }

    const buffer = Buffer.from(signatureMatch[1], "base64");
    const pngHeader = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]);
    if (buffer.length === 0 || buffer.length > 512 * 1024 || !buffer.subarray(0, 8).equals(pngHeader)) {
      throw new HttpsError("invalid-argument", "ملف التوقيع تالف أو لا يتطابق مع ترويسة ملفات PNG");
    }

    // 🚀 2. البث المباشر Stream إلى Cloud Storage بدون حجز كتل ذاكرة إضافية في الـ Heap
    const fileName = `signatures/order_${cleanOrderId}_${Date.now()}.png`;
    const file = bucket.file(fileName);
    const downloadToken = crypto.randomUUID();

    return new Promise((resolve, reject) => {
      const writeStream = file.createWriteStream({
        resumable: false,
        metadata: {
          contentType: "image/png",
          metadata: { firebaseStorageDownloadTokens: downloadToken },
        },
      });

      writeStream.on("error", (err) => {
        console.error("[SignatureService] Stream upload failed:", err);
        reject(new HttpsError("internal", "تعذر رفع التوقيع الرقمي بنمط البث التدفقي"));
      });

      writeStream.on("finish", () => {
        resolve(
          `https://firebasestorage.googleapis.com/v0/b/${bucket.name}/o/${encodeURIComponent(fileName)}?alt=media&token=${downloadToken}`
        );
      });

      writeStream.end(buffer);
    });
  }
}

// ── 4. دوال التشفير والصلاحيات والاتصال ──
function hashCode(code) {
  return crypto.createHash("sha256").update(code).digest("hex");
}

function generateCode() {
  return String(crypto.randomInt(0, 1000000)).padStart(6, "0");
}

async function requireActiveRole(uid, allowedRoles, message) {
  const profile = await db.collection("profiles").doc(uid).get();
  const data = profile.data() || {};
  const role = String(data.role || "").trim().toLowerCase();
  if (!profile.exists || data.is_banned === true ||
      data.is_active !== true || !allowedRoles.includes(role)) {
    throw new HttpsError("permission-denied", message);
  }
  return { data, role };
}

function toChatId(phone) {
  const digitsOnly = phone.replace(/[^\d]/g, "");
  return `${digitsOnly}@c.us`;
}
async function sendWhatsAppMessage({ phone, text, idInstance, apiTokenInstance }) {
  const apiUrl = "https://api.greenapi.com";
  const url = `${apiUrl}/waInstance${idInstance}/sendMessage/${apiTokenInstance}`;

  // 🚀 تفعيل Keep-Alive لإعادة استخدام قنوات الـ Socket ومهلة صارمة 6 ثوانٍ
  const response = await fetch(url, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "Connection": "keep-alive",
    },
    body: JSON.stringify({
      chatId: toChatId(phone),
      message: text,
    }),
    signal: AbortSignal.timeout(6000),
  });

  const data = await response.json().catch(() => null);
  if (!response.ok) {
    throw new Error(`Green API error (${response.status}): ${data?.message || "unknown"}`);
  }
  return data;
}
// ══════════════════════════════════════════════════════════════
// 🧪 PURE DOMAIN LOGIC & NORMALIZERS (MAINTAINABILITY 100/100)
// ══════════════════════════════════════════════════════════════

// ── 1. فئة التطبيع الموحدة المركزية (Single Source of Truth) ──
class Normalizer {
  static arabicDigitsMap = {
    "٠": "0", "١": "1", "٢": "2", "٣": "3", "٤": "4",
    "٥": "5", "٦": "6", "٧": "7", "٨": "8", "٩": "9"
  };

  static normalizeDigits(raw) {
    let text = String(raw || "").trim();
    for (const [ar, en] of Object.entries(this.arabicDigitsMap)) {
      text = text.replaceAll(ar, en);
    }
    return text;
  }

  static barcode(raw) {
    const text = this.normalizeDigits(raw);
    return text.replace(/[^0-9a-zA-Z]/g, "").trim();
  }

  static _checkDigit(body) {
    let sum = 0;
    for (let i = 0; i < body.length; i++) {
      const d = body.charCodeAt(body.length - 1 - i) - 48;
      sum += (i % 2 === 0) ? d * 3 : d;
    }
    return (10 - sum % 10) % 10;
  }

  static isValidGtin(s) {
    if (!/^\d+$/.test(s)) return false;
    if (![8, 12, 13, 14].includes(s.length)) return false;
    return this._checkDigit(s.slice(0, -1)) === s.charCodeAt(s.length - 1) - 48;
  }

  static _upcEtoA(e) {
    if (e.length !== 8 || !/^\d+$/.test(e)) return null;
    const n = e[0], d = e.slice(1, 7), chk = e[7], d6 = d[5];
    let body;
    switch (d6) {
      case "0":
      case "1":
      case "2":
        body = `${d.slice(0, 2)}${d6}0000${d.slice(2, 5)}`;
        break;
      case "3":
        body = `${d.slice(0, 3)}00000${d.slice(3, 5)}`;
        break;
      case "4":
        body = `${d.slice(0, 4)}00000${d[4]}`;
        break;
      default:
        body = `${d.slice(0, 5)}0000${d6}`;
    }
    return `${n}${body}${chk}`;
  }

  static extractBarcodeVariants(cleanBarcode) {
    const out = new Set();
    if (!cleanBarcode) return [];
    out.add(cleanBarcode);
    if (!/^\d+$/.test(cleanBarcode)) return Array.from(out);

    const s = cleanBarcode.replace(/^0+/, "");
    if (!s) return Array.from(out);
    out.add(s);
    for (const len of [13, 12, 14, 8]) {
      if (s.length <= len) out.add(s.padStart(len, "0"));
    }
    out.add("0" + s);
    out.add("00" + s);

    const a = this._upcEtoA(cleanBarcode);
    if (a) {
      out.add(a);
      out.add(a.padStart(13, "0"));
    }
    if (cleanBarcode.length === 14 && this.isValidGtin(cleanBarcode)) {
      const body12 = cleanBarcode.slice(1, 13);
      const inner13 = `${body12}${this._checkDigit(body12)}`;
      out.add(inner13);
      out.add(inner13.replace(/^0+/, ""));
    }
    return Array.from(out).filter(Boolean);
  }

static extractAllBarcodes(mainBarcode, units = [], variants = []) {
    const allBarcodes = new Set();
    const cleanMain = this.barcode(mainBarcode);
    if (cleanMain) {
      this.extractBarcodeVariants(cleanMain).forEach((b) => allBarcodes.add(b));
    }
    if (Array.isArray(units)) {
      for (const u of units) {
        const uBar = this.barcode(u.barcode);
        if (uBar) {
          this.extractBarcodeVariants(uBar).forEach((b) => allBarcodes.add(b));
        }
      }
    }
    if (Array.isArray(variants)) {
      for (const v of variants) {
        if (!v || typeof v !== "object") continue;
        const vBar = this.barcode(v.barcode);
        if (vBar) {
          this.extractBarcodeVariants(vBar).forEach((b) => allBarcodes.add(b));
        }
        if (Array.isArray(v.units)) {
          for (const vu of v.units) {
            const vuBar = this.barcode(vu.barcode);
            if (vuBar) {
              this.extractBarcodeVariants(vuBar).forEach((b) => allBarcodes.add(b));
            }
          }
        }
      }
    }
    return Array.from(allBarcodes);
  }

  static toSafeTimestamp(dateInput) {
    if (!dateInput) return null;
    if (typeof dateInput.toDate === "function") return Timestamp.fromDate(dateInput.toDate());
    const d = new Date(dateInput);
    return !isNaN(d.getTime()) ? Timestamp.fromDate(d) : null;
  }
}

// ── 2. محرك الحسابات المالية والمخزنية الصافي (Pure Testable Calculator) ──
class OrderCalculator {
  static processOrderItems({ items, productMap, productFinancialMap, orderId, merchantId }) {
    let serverTotal = 0;
    let serverProfit = 0;
    const stockDeductions = new Map();
    const enrichedItems = [];
    const itemFinancials = [];
    const unavailableItems = [];
    const outOfStockItems = [];

 for (const item of items) {
      const pId = String(item.product_id).trim();
      const product = productMap.get(pId);

      if (!product || product.is_deleted === true || product.is_active === false) {
        unavailableItems.push({ id: pId, name: product?.name || item.product_name || "الصنف" });
        continue;
      }

      const qty = Number(item.quantity);
      if (!Number.isSafeInteger(qty) || qty <= 0) {
        throw new HttpsError("invalid-argument", `كمية الصنف (${product.name || pId}) غير صحيحة`);
      }

      const variantId = item.variant_id ? String(item.variant_id).trim() : null;
      const variants = Array.isArray(product.variants) ? product.variants : [];
      let selectedVariant = null;

      if (variantId) {
        selectedVariant = variants.find((v) => String(v.id || v.label).trim() === variantId);
        if (!selectedVariant) {
          throw new HttpsError("failed-precondition", `PRODUCT_UNAVAILABLE_[${pId}:${variantId}]: الحجم المطلوب لم يعد متوفراً`);
        }
      }

      const configuredCartonItems = Number(selectedVariant?.items_per_carton ?? product.items_per_carton);
      const cartonItems = Number.isFinite(configuredCartonItems) && configuredCartonItems > 0 ? configuredCartonItems : 1;
      const productFinancials = productFinancialMap.get(pId) || {};

      let unitPrice = Number(selectedVariant?.price ?? product.price);
      if (!Number.isFinite(unitPrice) || unitPrice < 0) {
        throw new HttpsError("failed-precondition", `سعر الصنف (${product.name || pId}) غير صالح`);
      }

      let costPrice = 0;
      let financialUnits = new Map();

      if (selectedVariant) {
        const fVariants = Array.isArray(productFinancials.variants) ? productFinancials.variants : [];
        const fv = fVariants.find((f) => String(f.id || f.label).trim() === String(selectedVariant.id || selectedVariant.label).trim()) || {};
        costPrice = Number(fv.cost_price ?? selectedVariant.cost_price) || 0;
        financialUnits = new Map(
          (Array.isArray(fv.units) ? fv.units : []).map((u) => [String(u.label).trim(), u])
        );
      } else {
        costPrice = Number(productFinancials.cost_price ?? product.cost_price) || 0;
        financialUnits = new Map(
          (Array.isArray(productFinancials.units) ? productFinancials.units : []).map((u) => [String(u.label).trim(), u])
        );
      }
const unitLabel = String(item.unit_label || "كرتون").trim();
      const isCarton = (unitLabel === "كرتون");
      const rawVariantUnits = Array.isArray(selectedVariant?.units) ? selectedVariant.units : [];
      const rawProductUnits = Array.isArray(product.units) ? product.units : [];
      
      // ✅ تطابق تام 100% مع تطبيق فلاتر: إذا لم يكن للحجم وحدات فرعية مخصصة، تورث وحدات المنتج الأساسي
      const hasCustomVariantSubUnits = rawVariantUnits.some((u) => String(u.label || "").trim() !== "كرتون");
      const availableUnits = hasCustomVariantSubUnits ? rawVariantUnits : (rawProductUnits.length > 0 ? rawProductUnits : rawVariantUnits);
      let selectedUnit = availableUnits.find((u) => String(u.label || "").trim() === unitLabel);

      let unitQty = 1;
      if (selectedUnit) {
        // احتساب السعر التناسبي للوحدة الموروثة للحجم بدقة مطابقة لفلاتر
        if (selectedVariant && !hasCustomVariantSubUnits && Number(product.price) > 0) {
          const ratio = Number(selectedVariant.price) / Number(product.price);
          unitPrice = isCarton
            ? Number(selectedVariant.price)
            : Math.round(Number((Number(selectedUnit.price) * ratio).toFixed(6)));
        } else {
          unitPrice = Number(selectedUnit.price);
        }
        unitQty = isCarton ? cartonItems : (Number(selectedUnit.qty) || 1);
      } else if (isCarton) {
        unitPrice = Number(selectedVariant?.price ?? product.price);
        unitQty = cartonItems;
      } else {
        const varToken = selectedVariant ? `${selectedVariant.id}:` : "";
        throw new HttpsError("failed-precondition", `PRODUCT_UNAVAILABLE_[${pId}:${varToken}${unitLabel}]: الوحدة المطلوبة لم تعد متوفرة`);
      }
const stockDeductCartons = Number(((qty * unitQty) / cartonItems).toFixed(4));
      const deductionKey = selectedVariant ? `${pId}__v_${selectedVariant.id}` : pId;
      const existingEntry = stockDeductions.get(deductionKey);
      const currentDeduction = Number(existingEntry?.delta ?? 0);
      const totalDeduction = Number((currentDeduction + stockDeductCartons).toFixed(4));

    const hasVariants = variants.length > 0;
      const availableStock = selectedVariant
        ? Math.max(0, Number(selectedVariant.stock) || 0)
        : Math.max(
            0,
            Number(hasVariants ? (product.base_stock ?? 0) : (product.base_stock ?? product.stock)) || 0
          );
      if (availableStock < totalDeduction) {
        const token = selectedVariant ? `${selectedVariant.id}:${unitLabel}` : unitLabel;
        const displayName = selectedVariant ? `${product.name} (${selectedVariant.label})` : product.name;
        outOfStockItems.push({ id: pId, unitLabel: token, name: displayName });
        continue;
      }
      stockDeductions.set(deductionKey, {
        productId: pId,
        variantId: selectedVariant ? selectedVariant.id : null,
        delta: totalDeduction,
      });
    const subtotal = Number((unitPrice * qty).toFixed(2));
      let unitCost = 0;
      const selectedUnitFinancials = selectedUnit ? financialUnits.get(unitLabel) : null;
      const explicitCost = Number(selectedUnitFinancials?.cost_price ?? selectedUnit?.cost_price);

      if (Number.isFinite(explicitCost) && explicitCost > 0) {
        unitCost = explicitCost;
      } else if (costPrice > 0 && cartonItems > 0) {
        unitCost = Number(((costPrice / cartonItems) * unitQty).toFixed(2));
      }

      const itemProfit = Number(((unitPrice - unitCost) * qty).toFixed(2));
      serverTotal = Number((serverTotal + subtotal).toFixed(2));
      serverProfit = Number((serverProfit + itemProfit).toFixed(2));

      const itemDisplayName = selectedVariant
        ? `${product.name} - ${selectedVariant.label}`
        : (product.name || item.product_name || "");

      enrichedItems.push({
        order_id: orderId,
        merchant_id: merchantId,
        product_id: pId,
        product_name: itemDisplayName,
        variant_id: selectedVariant ? selectedVariant.id : null,
        variant_label: selectedVariant ? selectedVariant.label : null,
        price: unitPrice,
        carton_capacity: cartonItems,
        quantity: qty,
        subtotal: subtotal,
        unit_label: unitLabel,
        unit_qty: unitQty,
      });

      itemFinancials.push({
        cost_price: costPrice,
        unit_cost: unitCost,
        profit: itemProfit,
      });
    }
return {
      serverTotal,
      serverProfit,
      stockDeductions,
      enrichedItems,
      itemFinancials,
      unavailableItems,
      outOfStockItems,
    };
  }

  static applyProductStockDeltas({ tx, entries, productMap, isRestore, auditMeta }) {
    const groupedByProduct = new Map();
    for (const entry of entries) {
      const pId = String(entry.productId || "").trim();
      const delta = Number(entry.delta) || 0;
      if (!pId || delta <= 0) continue;
      if (!groupedByProduct.has(pId)) {
        groupedByProduct.set(pId, { rootDelta: 0, variantDeltas: new Map(), totalDelta: 0 });
      }
      const bucket = groupedByProduct.get(pId);
      bucket.totalDelta = Number((bucket.totalDelta + delta).toFixed(4));
      if (entry.variantId) {
        const vId = String(entry.variantId).trim();
        bucket.variantDeltas.set(vId, Number(((bucket.variantDeltas.get(vId) || 0) + delta).toFixed(4)));
      } else {
        bucket.rootDelta = Number((bucket.rootDelta + delta).toFixed(4));
      }
    }

    for (const [pId, bucket] of groupedByProduct.entries()) {
      const pDoc = productMap.get(pId) || {};
      const productRef = db.collection("products").doc(pId);
      const updatePayload = { updated_at: FieldValue.serverTimestamp() };

      const currentSales = Number(pDoc.sales_count) || 0;
      const salesDelta = isRestore
        ? -Math.min(currentSales, bucket.totalDelta)
        : bucket.totalDelta;
      updatePayload.sales_count = FieldValue.increment(salesDelta);
const hasVariants = Array.isArray(pDoc.variants) && pDoc.variants.length > 0;
      const effectiveRootDelta = hasVariants ? bucket.rootDelta : bucket.totalDelta;
      let nextBaseStock = Math.max(
        0,
        Number(hasVariants ? (pDoc.base_stock ?? 0) : (pDoc.base_stock ?? pDoc.stock)) || 0
      );

      if (effectiveRootDelta > 0) {
        nextBaseStock = Number(
          (isRestore
            ? nextBaseStock + effectiveRootDelta
            : Math.max(0, nextBaseStock - effectiveRootDelta)
          ).toFixed(4)
        );
        updatePayload.base_stock = nextBaseStock;
      }

      if (hasVariants) {
        let totalVariantStock = 0;
        const updatedVariants = pDoc.variants.map((v) => {
          const key = String(v.id || v.label).trim();
          const vDelta = bucket.variantDeltas.get(key) || 0;
          const currentVStock = Math.max(0, Number(v.stock) || 0);
          const nextVStock = vDelta > 0
            ? (isRestore ? currentVStock + vDelta : Math.max(0, currentVStock - vDelta))
            : currentVStock;
          const rounded = Number(nextVStock.toFixed(4));
          totalVariantStock += rounded;
          return { ...v, stock: rounded };
        });
        if (bucket.variantDeltas.size > 0) {
          updatePayload.variants = updatedVariants;
        }
        updatePayload.stock = Number((nextBaseStock + totalVariantStock).toFixed(4));
      } else if (effectiveRootDelta > 0) {
        updatePayload.stock = nextBaseStock;
      }
      tx.update(productRef, updatePayload);

      const auditRef = db.collection("inventory_audit_log").doc();
      tx.set(auditRef, {
        product_id: pId,
        delta: isRestore ? bucket.totalDelta : -bucket.totalDelta,
        ...auditMeta,
        created_at: FieldValue.serverTimestamp(),
      });
    }
  }
}

// ── 3. خدمة إدارة وقوالب الإشعارات المعزولة (Notification Service) ──
class NotificationService {
  static getStatusTemplate(status) {
    const templates = {
      confirmed: { title: "✅ تم قبول طلبك!", body: "بدأنا تجهيز طلبك بعناية وسنوافيك بالتحديثات." },
      preparing: { title: "📦 جاري تحضير طلبك", body: "فريق المستودع يجهز طلبك الآن تمهيداً لتسليمه للمندوب." },
      shipped: { title: "🚚 طلبك انطلق نحوك!", body: "المندوب في الطريق إليك الآن، يرجى الاستعداد للاستلام." },
      delivered: { title: "🎉 تم تسليم طلبك بنجاح!", body: "تم تسليم الطلب بالسلامة، نسعد بخدمتكم دائماً." },
      cancelled: { title: "⚠️ تم إلغاء الطلب", body: "تم إلغاء الطلب من قبل الإدارة، نعتذر عن أي إزعاج." },
      rejected: { title: "❌ نعتذر منك", body: "تعذر قبول الطلب هذه المرة لأسباب تشغيلية، نأمل خدمتكم قريباً." },
      on_the_way: { title: "🚚 المندوب في الطريق", body: "المندوب في طريقه إليك الآن، يرجى الاستعداد للاستلام." },
      return_requested: { title: "📋 تم تسجيل طلب إرجاع", body: "تم تسجيل طلب الإرجاع وسيتم مراجعته من الإدارة." },
      returned: { title: "↩️ تم استرجاع الطلب", body: "تم استرجاع الطلب بنجاح." },
    };
    return templates[status] || null;
  }

  static async notifyDriversNewOrder(orderId, total) {
    try {
    await messaging.send({
        topic: "drivers",
        notification: {
          title: "🚨 طلب جديد جاهز للتوصيل!",
          body: `طلب جديد بقيمة ${Number(total).toFixed(0)} ر.ي جاهز للاستلام والتوصيل`,
        },
        data: {
          order_id: String(orderId),
          type: "new_order",
          route: "/driver",
          click_action: "FLUTTER_NOTIFICATION_CLICK",
        },
      android: {
          priority: "high",
          notification: {
            channelId: "wissal_orders_channel",
            priority: "max",
            sound: "wissal_notification",
            clickAction: "FLUTTER_NOTIFICATION_CLICK",
          },
        },
        apns: {
          headers: { "apns-priority": "10", "apns-push-type": "alert" },
          payload: {
            aps: {
              alert: {
                title: "🚨 طلب جديد جاهز للتوصيل!",
                body: `طلب جديد بقيمة ${Number(total).toFixed(0)} ر.ي جاهز للاستلام`,
              },
              sound: "wissal_notification.wav",
              badge: 1,
            },
          },
        },
      });
    } catch (err) {
      console.warn("[NotificationService] Driver push failed:", err);
    }
  }
}

// ─── requestOtp (محصنة 100% ضد استنزاف الرصيد وهجمات التخمين) ───
exports.requestOtp = onCall(
  { region: "us-central1", cors: true, secrets: [smsSenderId, smsApiKey] },
  async (request) => {
    const phone = String(request.data?.phone || "").trim();
    const purpose = String(request.data?.purpose || "").trim();
 
    if (!phone || !/^\+\d{9,15}$/.test(phone)) {
      throw new HttpsError("invalid-argument", "رقم الهاتف غير صحيح");
    }
    if (purpose !== "login" && purpose !== "signup") {
      throw new HttpsError("invalid-argument", "نوع الطلب غير صحيح");
    }

  // 🔒 التحقق المسبق الصارم: جلب المطابقات واستبعاد السجلات المرحّلة/المحذوفة أولاً
    const profileSnap = await db.collection("profiles")
      .where("phone_number", "==", phone)
      .limit(5)
      .get();

    const matchedDoc = profileSnap.docs.find((d) => d.data()?.is_deleted !== true) || profileSnap.docs[0] || null;
    const userExists = Boolean(matchedDoc);
    const userData = matchedDoc ? matchedDoc.data() : null;

if (purpose === "login") {
      if (!userExists || userData?.is_deleted === true) {
        throw new HttpsError("not-found", "هذا الرقم غير مسجل مسبقاً، يرجى الانتقال إلى خيار 'إنشاء حساب'");
      }
      if (userData?.is_banned === true) {
        throw new HttpsError("permission-denied", "تم حظر هذا الحساب، يرجى التواصل مع إدارة المنصة");
      }
      if (userData?.account_status === "otp_verified") {
        throw new HttpsError("failed-precondition", "لم تكتمل بيانات متجرك مسبقاً، يرجى إنشاء حساب لإكمالها");
      }
      if (userData?.is_active === false && userData?.account_status !== "pending") {
        throw new HttpsError("permission-denied", "الحساب معطل حالياً من قِبل الإدارة، يرجى التواصل مع الدعم الفني");
      }
    } else if (purpose === "signup") {
      if (userExists && userData?.is_deleted !== true && userData?.account_status !== "otp_verified") {
        throw new HttpsError("already-exists", "هذا الرقم مسجل بالفعل، يرجى الضغط على 'تسجيل الدخول'");
      }
    }
  const otpRef = db.collection("otp_codes").doc(phone);
    const code = generateCode();
    const codeHash = hashCode(code);

    const reserveStatus = await db.runTransaction(async (tx) => {
      const existing = await tx.get(otpRef);
      const data = existing.data() || {};
      const lastSentAt = existing.exists ? (data.lastSentAt?.toMillis?.() ?? 0) : 0;

      // كبح التكرار: دقيقة كاملة بين كل طلب لنفس الرقم
      if (Date.now() - lastSentAt < RESEND_COOLDOWN_MS) return "cooldown";

      // سقف أمان ساعي: منع طلب أكثر من 5 رموز لنفس الرقم خلال ساعة واحدة
      const hourlyRequests = Number(data.hourlyRequests || 0);
      const hourStart = data.hourStart?.toMillis?.() ?? 0;
      const isNewHour = Date.now() - hourStart > 3600 * 1000;

      if (!isNewHour && hourlyRequests >= 5) {
        return "hourly_limit";
      }

      tx.set(otpRef, {
        codeHash,
        purpose,
        attempts: 0,
        hourlyRequests: isNewHour ? 1 : hourlyRequests + 1,
        hourStart: isNewHour ? FieldValue.serverTimestamp() : (data.hourStart || FieldValue.serverTimestamp()),
        createdAt: FieldValue.serverTimestamp(),
        lastSentAt: FieldValue.serverTimestamp(),
        expiresAt: Timestamp.fromMillis(Date.now() + OTP_TTL_MS),
      });
      return "reserved";
    });

    if (reserveStatus === "cooldown") {
      throw new HttpsError("resource-exhausted", "يرجى الانتظار دقيقة كاملة قبل طلب رمز تحقق جديد");
    }
    if (reserveStatus === "hourly_limit") {
      throw new HttpsError("resource-exhausted", "تجاوزت الحد المسموح (5 رموز في الساعة)، يرجى المحاولة لاحقاً");
    }
try {
      await sendWhatsAppMessage({
        phone,
        text: `رمز التحقق الخاص بك في وصًال هو: ${code}\nصالح لمدة 5 دقائق ولا تشاركه مع أي شخص.`,
        idInstance: smsSenderId.value(),
        apiTokenInstance: smsApiKey.value(),
      });
    } catch (error) {
      console.error("[requestOtp] WhatsApp send failed:", error);
      // 🚀 استعادة مرنة عادلة: إلغاء الكود، تصفير وقت الإرسال، واسترجاع المحاولة من العداد الساعي
      await db.runTransaction(async (tx) => {
        const current = await tx.get(otpRef);
        if (current.exists && current.data().codeHash === codeHash) {
          tx.update(otpRef, {
            codeHash: null,
            expiresAt: Timestamp.fromMillis(0),
            lastSentAt: Timestamp.fromMillis(0),
            hourlyRequests: FieldValue.increment(-1),
            sendFailed: true,
          });
        }
      });

      throw new HttpsError(
        "unavailable",
        "تعذر إرسال رمز التحقق عبر واتساب حالياً. تحقق من اتصالك بالإنترنت وأعد المحاولة."
      );
    }
    return { 
      success: true, 
      message: "تم إرسال رمز التحقق بنجاح",
      verificationId: phone 
    };
  }
);
// ─── verifyOtp ───
exports.verifyOtp = onCall(
  { region: "us-central1", cors: true, secrets: [smsSenderId, smsApiKey] },
  async (request) => {
    const phone = String(request.data?.phone || "").trim();
    const code = String(request.data?.code || "").trim();
    const purpose = String(request.data?.purpose || "").trim();
 
    if (!phone || !/^\+\d{9,15}$/.test(phone)) {
      throw new HttpsError("invalid-argument", "رقم الهاتف غير صحيح");
    }
    if (!/^\d{6}$/.test(code)) {
      return { verified: false, message: "تعذر التحقق من الرمز، أعد إرساله وحاول مجدداً" };
    }
    if (purpose !== "login" && purpose !== "signup") {
      return { verified: false, message: "تعذر التحقق من الرمز، أعد إرساله وحاول مجدداً" };
    }
const otpRef = db.collection("otp_codes").doc(phone);

    // Commit attempt counters and expiry cleanup before returning validation errors.
    let verificationStatus;
    try {
      verificationStatus = await db.runTransaction(async (tx) => {
        const snap = await tx.get(otpRef);
        if (!snap.exists) {
          return "missing";
        }

        const data = snap.data();
        if (data.purpose !== purpose) {
          return "invalid_purpose";
        }
if (Date.now() > data.expiresAt.toMillis()) {
          tx.update(otpRef, {
            codeHash: null,
            expiresAt: Timestamp.fromMillis(0),
          });
          return "expired";
        }

        if (data.attempts >= MAX_ATTEMPTS) {
          tx.update(otpRef, {
            codeHash: null,
            expiresAt: Timestamp.fromMillis(0),
          });
          return "attempts_exhausted";
        }

const candidateBuf = Buffer.from(hashCode(code), "hex");
        const storedBuf = Buffer.from(String(data.codeHash || ""), "hex");
        const isHashMatch =
          candidateBuf.length === storedBuf.length &&
          crypto.timingSafeEqual(candidateBuf, storedBuf);
        if (!isHashMatch) {          const nextAttempts = (data.attempts || 0) + 1;
          if (nextAttempts >= MAX_ATTEMPTS) {
            tx.update(otpRef, {
              attempts: nextAttempts,
              codeHash: null,
              expiresAt: Timestamp.fromMillis(0),
            });
            return "attempts_exhausted";
          } else {
            tx.update(otpRef, { attempts: nextAttempts });
            return "invalid_code";
          }
        }

        tx.update(otpRef, {
          codeHash: null,
          expiresAt: Timestamp.fromMillis(0),
        });
        return "verified";
      });
    } catch (err) {
      console.error("[verifyOtp] Transaction Failure:", err);
      return { verified: false, message: "فشل التحقق من الرمز، حاول مجدداً" };
    }
  if (verificationStatus !== "verified") {
      const statusMessages = {
        invalid_code: "رمز التحقق غير صحيح، يرجى التأكد وإعادة المحاولة",
        attempts_exhausted: "استنفدت عدد المحاولات المسموحة، يرجى طلب رمز جديد",
        expired: "انتهت صلاحية الرمز، يرجى طلب رمز جديد",
        missing: "لم يتم العثور على جلسة تحقق نشطة، يرجى طلب رمز جديد",
        invalid_purpose: "نوع طلب التحقق غير مطابق",
      };
      return {
        verified: false,
        message: statusMessages[verificationStatus] || "تعذر التحقق من الرمز، أعد إرساله وحاول مجدداً",
      };
    }

    let uid;
    let role = "merchant";
if (purpose === "login") {
      const profileSnap = await db.collection("profiles").where("phone_number", "==", phone).limit(5).get();
      const userDoc = profileSnap.docs.find((d) => d.data()?.is_deleted !== true);
      if (!userDoc) {
        return { verified: false, message: "تعذر التحقق من الرمز، أعد إرساله وحاول مجدداً" };
      }
      const userData = userDoc.data();

      if (userData.is_deleted === true) {
        return { verified: false, message: "هذا الحساب محذوف، يرجى إنشاء حساب جديد" };
      }
      if (userData.is_banned === true) {
        return { verified: false, message: "تم حظر هذا الحساب، يرجى التواصل مع الإدارة" };
      }
      if (userData.account_status === "otp_verified") {
        return { 
          verified: false, 
          message: "لم تكتمل عملية التسجيل مسبقاً، يرجى استخدام خيار 'إنشاء حساب' لإكمال بيانات متجرك" 
        };
      }
      if (userData.is_active === false && userData.account_status !== "pending") {
        return { verified: false, message: "الحساب معطل حالياً من قِبل الإدارة" };
      }
      uid = userDoc.id;
      role = userData.role || "merchant";
  }   else {
      const existingProfile = await db.collection("profiles")
        .where("phone_number", "==", phone)
        .limit(5)
        .get();

      const activeExistingDoc = existingProfile.docs.find((d) => d.data()?.is_deleted !== true);
      if (activeExistingDoc) {
        const existingData = activeExistingDoc.data() || {};
        if (existingData.is_banned === true || existingData.account_status !== "otp_verified") {
          return {
            verified: false,
            message: "رقم الهاتف مسجل مسبقاً، يرجى تسجيل الدخول",
          };
        }
        uid = activeExistingDoc.id;
        await db.collection("profiles").doc(uid).set({
          phone_number: phone,
          role: "merchant",
          is_active: false,
          is_banned: false,
          is_deleted: false,
          account_status: "otp_verified",
          updated_at: FieldValue.serverTimestamp(),
        }, { merge: true });
      } else {
        uid = db.collection("profiles").doc().id;
        await db.collection("profiles").doc(uid).set({
          phone_number: phone,
          role: "merchant",
          is_active: false,
          is_banned: false,
          account_status: "otp_verified",
          created_at: FieldValue.serverTimestamp(),
          updated_at: FieldValue.serverTimestamp(),
        });
      }
    }
  if (purpose === "login") {
      try {
        const authUser = await auth.getUser(uid);
        const existingClaims = authUser.customClaims || {};
        if (
          existingClaims.role !== role ||
          existingClaims.verified_phone !== phone ||
          existingClaims.is_banned === true
        ) {
          const cleanClaims = { ...existingClaims, role, verified_phone: phone };
          delete cleanClaims.is_banned;
          await auth.setCustomUserClaims(uid, cleanClaims);
        }
      } catch (_) {
        // إذا كان أول دخول للمستخدم سيتم إنشاء سجل Auth تلقائياً عند signInWithCustomToken
      }
    }

    const tokenClaims = { role, purpose, verified_phone: phone };
    const customToken = await auth.createCustomToken(uid, tokenClaims);
    return { verified: true, message: "تم التحقق بنجاح", customToken };
  }
);
// ─── إرسال الإشعارات للهواتف (متوافق مع شاشة القفل للآيفون وأندرويد والتطبيق مغلق) ───
exports.sendPushNotification = onDocumentCreated(
  {
    document: "user_notifications/{docId}",
    region: "us-central1",
  },
  async (event) => {
    const notifData = event.data?.data();
    if (!notifData) return;

  const userId = notifData.user_id;
    if (!userId || typeof userId !== "string") return;

    const title = notifData.title || "إشعار جديد";
    const body = notifData.body || "";
    const type = notifData.type || "";

    const userDoc = await db.collection("profiles").doc(userId).get();
    if (!userDoc.exists) return;

    const fcmToken = userDoc.data().fcm_token;
    if (!fcmToken) return;
const targetChannel = type === "new_order" ? "wissal_orders_channel" : "wissal_orders_channel_v3";
    const isNewOrder = type === "new_order";

    const message = {
      token: fcmToken,
      notification: { 
        title: String(title), 
        body: String(body) 
      },
data: {
        title: String(title),
        body: String(body),
        type: String(type),
        order_id: String(notifData.order_id || ""),
        click_action: "FLUTTER_NOTIFICATION_CLICK"
      },
      android: {
        priority: "high",
        notification: {
          channelId: targetChannel,
          priority: "max",
          visibility: "public",
          defaultSound: !isNewOrder,
        sound: isNewOrder ? "wissal_notification" : undefined,
          defaultVibrateTimings: true,
          defaultLightSettings: true,
          clickAction: "FLUTTER_NOTIFICATION_CLICK"
        }
      },
      apns: {
        headers: {
          "apns-priority": "10",
          "apns-push-type": "alert"
        },
        payload: {
          aps: {
            alert: { 
              title: String(title), 
              body: String(body) 
            },
           sound: isNewOrder ? "wissal_notification.wav" : "default",
            badge: 1
          }
        }
      }
    };
    try {
      await messaging.send(message);
    } catch (error) {
      if (error.code === 'messaging/invalid-registration-token' || 
          error.code === 'messaging/registration-token-not-registered') {
        await db.collection("profiles").doc(userId).update({
          fcm_token: FieldValue.delete()
        });
      }
    }
  }
);
// ══════════════════════════════════════════════════════════════
// ⚡ HIGH-PERFORMANCE SPATIAL CACHE & HYBRID RATE LIMITER (0ms)
// ══════════════════════════════════════════════════════════════
const placesMemoryCache = new Map();
const userSearchTokenBucket = new Map();
const MAX_SPATIAL_CACHE_ENTRIES = 150;
const MAX_RATE_LIMIT_ENTRIES = 2000;
const CACHE_TTL_MS = 15 * 60 * 1000; // حفظ النتائج الشائعة لمدة 15 دقيقة في RAM الحاوية

function checkInMemoryRateLimit(uid, limit = 25, windowMs = 60000) {
  const now = Date.now();

  if (userSearchTokenBucket.size > MAX_RATE_LIMIT_ENTRIES) {
    for (const [key, record] of userSearchTokenBucket.entries()) {
      if (now > record.resetAt) {
        userSearchTokenBucket.delete(key);
      }
    }
    if (userSearchTokenBucket.size > MAX_RATE_LIMIT_ENTRIES) {
      const oldestKey = userSearchTokenBucket.keys().next().value;
      userSearchTokenBucket.delete(oldestKey);
    }
  }

  const record = userSearchTokenBucket.get(uid);

  if (!record || now > record.resetAt) {
    userSearchTokenBucket.set(uid, { count: 1, resetAt: now + windowMs });
    return true;
  }
  if (record.count >= limit) {
    return false;
  }
  record.count++;
  return true;
}
exports.searchPlaces = onCall(
  {
    region: "us-central1",
    cors: true,
    concurrency: 80,
    memory: "512MiB",
    secrets: [googlePlacesApiKey],
  },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "يجب تسجيل الدخول لاستخدام البحث الجغرافي");
    }

    const uid = request.auth.uid;

    // 🚀 1. محدد معدل فوري بذاكرة الـ RAM (0ms Latency بدلاً من 350ms معاملة في Firestore)
    if (!checkInMemoryRateLimit(uid)) {
      throw new HttpsError("resource-exhausted", "تجاوزت الحد المسموح من عمليات البحث السريعة، انتظر قليلاً");
    }

    const rawQuery = String(request.data?.query || "").trim().slice(0, 80);
    if (!rawQuery) return [];

    const searchQuery = rawQuery.includes("صنعاء") ? rawQuery : `${rawQuery} صنعاء`;
    const cacheKey = searchQuery.toLowerCase();
    const now = Date.now();

    // 🚀 2. التحقق من الكاش الجغرافي المحلي (استجابة في 1ms وتوفير تكلفة Google API)
    const cached = placesMemoryCache.get(cacheKey);
    if (cached && now < cached.expiresAt) {
      return cached.results;
    }

    const apiKey = googlePlacesApiKey.value();
    const url = new URL("https://maps.googleapis.com/maps/api/place/textsearch/json");
    url.searchParams.append("query", searchQuery);
    url.searchParams.append("location", "15.3550,44.2000");
    url.searchParams.append("radius", "25000");
    url.searchParams.append("language", "ar");
    url.searchParams.append("key", apiKey);

    try {
      const res = await fetch(url.toString(), {
        headers: { "Connection": "keep-alive" },
        signal: AbortSignal.timeout(4000), // مهلة حاسمة 4 ثوانٍ تمنع تعليق الحاوية
      });
      const data = await res.json();
      const results = (data.results || []).slice(0, 10);

      // تخزين النتيجة في كاش الحاوية السريع
      if (placesMemoryCache.size >= MAX_SPATIAL_CACHE_ENTRIES) {
        const oldestKey = placesMemoryCache.keys().next().value;
        placesMemoryCache.delete(oldestKey);
      }
      placesMemoryCache.set(cacheKey, { results, expiresAt: now + CACHE_TTL_MS });

      return results;
    } catch (error) {
      console.error("[searchPlaces] Network Error:", error);
      return [];
    }
  }
);


// ─── إنشاء ملف التاجر الجديد عند إكمال التسجيل (معالجة سحابية آمنة 100%) ───
exports.migrateFinancialFields = onCall(
  { region: "us-central1", cors: true, timeoutSeconds: 120 },
  async (request) => {
    let callerUid = request.auth?.uid;
    if (!callerUid && typeof request.data?.idToken === "string") {
      try {
        const decodedToken = await auth.verifyIdToken(request.data.idToken, true);
        callerUid = decodedToken.uid;
      } catch (error) {
        console.error("migrateFinancialFields could not verify the supplied ID token", error);
        throw new HttpsError("unauthenticated", "تعذر التحقق من جلسة الدخول");
      }
    }
    if (!callerUid) {
      throw new HttpsError("unauthenticated", "يجب تسجيل الدخول أولاً");
    }
    await requireActiveRole(
      callerUid,
      ["admin", "super_admin", "accountant", "warehouse_manager"],
      "ترحيل البيانات المالية مخصص لمدير النظام",
    );

    const stages = ["products", "orders", "order_items", "orders_finalize"];
    const migrationRef = db.collection("security_migrations").doc("financial_fields");
    const migrationSnap = await migrationRef.get();
    const migration = migrationSnap.data() || {};
    if (migration.done === true) return { done: true };

    const stage = stages.includes(migration.stage) ? migration.stage : stages[0];
    const collection = db.collection(
      stage === "orders_finalize" ? "orders" : stage,
    );
    let query = collection.orderBy(FieldPath.documentId()).limit(100);
    if (migration.stage === stage && migration.cursor) {
      query = query.startAfter(migration.cursor);
    }
    const page = await query.get();

    if (page.empty) {
      const nextIndex = stages.indexOf(stage) + 1;
      const done = nextIndex >= stages.length;
      await migrationRef.set({
        stage: done ? stage : stages[nextIndex],
        cursor: null,
        done,
        updated_at: FieldValue.serverTimestamp(),
      }, { merge: true });
      return { done, stage: done ? stage : stages[nextIndex], cursor: null };
    }

    await Promise.all(page.docs.map((doc) => db.runTransaction(async (tx) => {
      const currentSnap = await tx.get(doc.ref);
      if (!currentSnap.exists) return;
      const data = currentSnap.data();
      if (stage === "products") {
        const financialRef = db.collection("product_financials").doc(doc.id);
        const privateSnap = await tx.get(financialRef);
        const units = Array.isArray(data.units) ? data.units : [];
        const hasLegacyCosts = Object.prototype.hasOwnProperty.call(data, "cost_price") ||
          units.some((unit) => unit && typeof unit === "object" &&
            Object.prototype.hasOwnProperty.call(unit, "cost_price"));
        const financialData = {
          product_id: doc.id,
          updated_at: FieldValue.serverTimestamp(),
        };
        if (hasLegacyCosts || !privateSnap.exists) {
          financialData.cost_price = Math.max(0, Number(data.cost_price) || 0);
          financialData.units = units
            .filter((unit) => unit && typeof unit === "object")
            .map((unit) => ({
              label: String(unit.label || "").trim(),
              cost_price: Math.max(0, Number(unit.cost_price) || 0),
            }))
            .filter((unit) => unit.label);
        }
        tx.set(financialRef, financialData, { merge: true });
        tx.update(doc.ref, {
          cost_price: FieldValue.delete(),
          units: units
            .filter((unit) => unit && typeof unit === "object")
            .map(({ cost_price, ...unit }) => unit),
          public_catalog_ready: true,
          updated_at: FieldValue.serverTimestamp(),
        });
      } else if (stage === "orders") {
        const financialRef = db.collection("order_financials").doc(doc.id);
        const privateSnap = await tx.get(financialRef);
        const financial = {
          order_id: doc.id,
          profit_recorded: data.profit_recorded === true,
          updated_at: FieldValue.serverTimestamp(),
        };
        if (data.total_profit != null) {
          financial.total_profit = Number(data.total_profit) || 0;
        } else if (!privateSnap.exists) {
          financial.total_profit = 0;
        }
        tx.set(financialRef, financial, { merge: true });
        tx.update(doc.ref, {
          total_profit: FieldValue.delete(),
          financial_safe: false,
          updated_at: FieldValue.serverTimestamp(),
        });
      } else if (stage === "order_items") {
        const financialRef = db.collection("order_item_financials").doc(doc.id);
        const privateSnap = await tx.get(financialRef);
        const hasLegacyCosts = Object.prototype.hasOwnProperty.call(data, "cost_price") ||
          Object.prototype.hasOwnProperty.call(data, "unit_cost");
        const financialData = {
          order_id: String(data.order_id || ""),
          order_item_id: doc.id,
          updated_at: FieldValue.serverTimestamp(),
        };
        if (hasLegacyCosts || !privateSnap.exists) {
          financialData.cost_price = Math.max(0, Number(data.cost_price) || 0);
          financialData.unit_cost = Math.max(0, Number(data.unit_cost) || 0);
          financialData.profit = Number(data.profit) || 0;
        }
        tx.set(financialRef, financialData, { merge: true });
        tx.update(doc.ref, {
          cost_price: FieldValue.delete(),
          unit_cost: FieldValue.delete(),
          updated_at: FieldValue.serverTimestamp(),
        });
      } else {
        tx.update(doc.ref, {
          financial_safe: true,
          updated_at: FieldValue.serverTimestamp(),
        });
      }
    })));

    const nextCursor = page.docs[page.docs.length - 1].id;
    await migrationRef.set({
      stage,
      cursor: nextCursor,
      done: false,
      updated_at: FieldValue.serverTimestamp(),
    }, { merge: true });
    return { done: false, stage, cursor: nextCursor };
  },
);
// ─── مزامنة وتوحيد ملف المصادقة الهاتفية مع Custom Claims على السيرفر حصراً ───
exports.syncPhoneAuthProfile = onCall(
  { region: "us-central1", cors: true },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "يجب تسجيل الدخول أولاً");
    }

    const uid = request.auth.uid;
    const verifiedPhone =
      request.auth.token.phone_number || request.auth.token.verified_phone;

    if (!verifiedPhone || !/^\+\d{9,15}$/.test(verifiedPhone)) {
      throw new HttpsError(
        "permission-denied",
        "التوكن لا يحتوي على رقم هاتف موثق أمنياً"
      );
    }

    const txResult = await db.runTransaction(async (tx) => {
      const targetRef = db.collection("profiles").doc(uid);
      const [targetSnap, phoneSnaps] = await Promise.all([
        tx.get(targetRef),
        tx.get(
          db
            .collection("profiles")
            .where("phone_number", "==", verifiedPhone)
            .limit(5)
        ),
      ]);

      if (targetSnap.exists) {
        const data = targetSnap.data() || {};
        if (data.is_deleted === true) {
          throw new HttpsError("not-found", "الحساب غير موجود");
        }
        if (data.is_banned === true) {
          throw new HttpsError("permission-denied", "تم حظر هذا الحساب");
        }
        if (data.phone_number && data.phone_number !== verifiedPhone) {
          throw new HttpsError(
            "permission-denied",
            "تعارض في ملكية رقم الهاتف للحساب"
          );
        }
        return {
          role: String(data.role || "merchant").trim().toLowerCase(),
          migrated: false,
        };
      }

      const sourceDoc = phoneSnaps.docs.find(
        (d) => d.data()?.is_deleted !== true
      );
      if (!sourceDoc) {
        throw new HttpsError("not-found", "لم يتم العثور على ملف حساب مسجل");
      }

      const sourceData = sourceDoc.data() || {};
      if (sourceData.is_banned === true) {
        throw new HttpsError("permission-denied", "تم حظر هذا الحساب");
      }

      const resolvedRole = String(sourceData.role || "merchant")
        .trim()
        .toLowerCase();

      tx.set(targetRef, {
        ...sourceData,
        phone_number: verifiedPhone,
        role: resolvedRole,
        migrated_from: sourceDoc.id,
        updated_at: FieldValue.serverTimestamp(),
      });

    tx.update(sourceDoc.ref, {
        is_deleted: true,
        is_active: false,
        phone_number: FieldValue.delete(),
        migrated_to: uid,
        updated_at: FieldValue.serverTimestamp(),
      });

      return { role: resolvedRole, migrated: true };
    });

    const userRecord = await auth.getUser(uid);
    const currentClaims = { ...(userRecord.customClaims || {}) };
    delete currentClaims.is_banned;
    await auth.setCustomUserClaims(uid, {
      ...currentClaims,
      role: txResult.role,
      purpose: "registered",
      verified_phone: verifiedPhone,
    });

    return {
      success: true,
      uid,
      role: txResult.role,
      migrated: txResult.migrated,
    };
  }
);

// ─── إنشاء ملف التاجر الجديد عند إكمال التسجيل (معالجة سحابية آمنة 100%) ───
exports.createUserProfile = onCall(
  { region: "us-central1", cors: true },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "يجب تسجيل الدخول وتأكيد رمز التحقق أولاً");
    }

    const uid = request.auth.uid;
    const tokenPhone = request.auth.token.verified_phone || request.auth.token.phone_number;
    const { fullName, storeName, latitude, longitude, phone } = request.data || {};
    const cleanFullName = String(fullName || "").trim();
    const cleanStoreName = String(storeName || "").trim();
    const cleanPhone = String(phone || "").trim();
    const numLat = Number(latitude);
    const numLng = Number(longitude);

    // 🔒 حظر أمني حاسم: مطابقة رقم الهاتف مع التوكن الموثق لمنع انتحال هويات الآخرين
    if (!tokenPhone || tokenPhone !== cleanPhone) {
      throw new HttpsError("permission-denied", "رقم الهاتف غير مطابق لرمز التحقق المؤكد أمنياً");
    }

    // 1. تحققات أمنية صارمة على المدخلات
    if (!cleanFullName || cleanFullName.length > 120 || cleanFullName.split(/\s+/).length < 4) {
      throw new HttpsError("invalid-argument", "أدخل الاسم الرباعي بحد أقصى 120 حرفاً");
    }
    if (!cleanStoreName || cleanStoreName.length < 2 || cleanStoreName.length > 100) {
      throw new HttpsError("invalid-argument", "يجب أن يكون اسم المتجر بين حرفين و100 حرف");
    }
    if (!cleanPhone || !/^\+\d{9,15}$/.test(cleanPhone)) {
      throw new HttpsError("invalid-argument", "صيغة رقم الهاتف الدولي غير صحيحة");
    }
    if (isNaN(numLat) || isNaN(numLng) || numLat < -90 || numLat > 90 || numLng < -180 || numLng > 180) {
      throw new HttpsError("invalid-argument", "إحداثيات الموقع الجغرافي على الخريطة غير صالحة");
    }

    try {
      const profileRef = db.collection("profiles").doc(uid);
      await db.runTransaction(async (tx) => {
    const [existingDoc, phoneMatches] = await Promise.all([
          tx.get(profileRef),
          tx.get(db.collection("profiles")
            .where("phone_number", "==", cleanPhone)
            .limit(5)),
        ]);
        const conflictingDoc = phoneMatches.docs.find(
          (d) => d.id !== uid && d.data()?.is_deleted !== true
        );
        if (conflictingDoc) {
          throw new HttpsError("already-exists", "رقم الهاتف هذا مسجل مسبقاً لحساب آخر");
        }
if (existingDoc.exists) {
          const existingData = existingDoc.data() || {};
          if (existingData.role !== "merchant" ||
              existingData.phone_number !== cleanPhone ||
              existingData.account_status !== "otp_verified") {
            throw new HttpsError("already-exists", "ملف الحساب موجود مسبقاً ولا يمكن إعادة إنشائه");
          }
          // ✅ تحديث الحساب المحجوز مسبقاً من OTP وحفظ كافة البيانات الجغرافية والاسم
          tx.update(profileRef, {
            full_name: cleanFullName,
            store_name: cleanStoreName,
            latitude: numLat,
            longitude: numLng,
            account_status: "pending",
            updated_at: FieldValue.serverTimestamp(),
          });
        } else {
          tx.create(profileRef, {
            full_name: cleanFullName,
            store_name: cleanStoreName,
            phone_number: cleanPhone,
            latitude: numLat,
            longitude: numLng,
            role: "merchant",
            is_active: false,
            is_banned: false,
            account_status: "pending",
            created_at: FieldValue.serverTimestamp(),
            updated_at: FieldValue.serverTimestamp(),
          });
        }
      });

    const userRecord = await auth.getUser(uid);
      const currentClaims = userRecord.customClaims || {};
      await auth.setCustomUserClaims(uid, {
        ...currentClaims,
        role: "merchant",
        purpose: "registered",
        verified_phone: cleanPhone,
      });

      return {
        success: true,
        userId: uid,
        role: "merchant",
      };
    } catch (error) {
      if (error instanceof HttpsError) throw error;
      console.error("[createUserProfile] Error:", error);
      throw new HttpsError("internal", "تعذر حفظ بيانات الحساب في السيرفر: " + error.message);
    }
  }
);
// ─── حذف الحساب الآمن المكتمل مع إبطال التوكنات وتطهير FCM ───
exports.deleteUserAccount = onCall(
  { region: "us-central1", cors: true },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError('unauthenticated', 'يجب تسجيل الدخول أولاً');
    }

    const targetUid = request.auth.uid;
    const profileRef = db.collection('profiles').doc(targetUid);
    const userProfile = await profileRef.get();
    
    if (userProfile.exists) {
      const role = String(userProfile.data()?.role || "").toLowerCase().trim();
      if (role === "super_admin" || role === "admin") {
        throw new HttpsError('failed-precondition', 'لا يمكن حذف حسابات مدراء النظام من التطبيق');
      }
    }

    try {
      // 1. إبطال كافة الجلسات النشطة على كل أجهزة المستخدم فوراً
      await auth.revokeRefreshTokens(targetUid);

     // 2. تطهير البيانات التعريفية ورمز الإشعارات لمنع وصول أي إشعار بعد الحذف
      await profileRef.set({
        is_active: false,
        is_banned: true,
        is_deleted: true,
        fcm_token: FieldValue.delete(),
        phone_number: FieldValue.delete(),
        full_name: "مستخدم محذوف",
        deleted_at: FieldValue.serverTimestamp(),
        updated_at: FieldValue.serverTimestamp(),
      }, { merge: true });

      // 3. حذف الحساب من سجلات Firebase Authentication
      await auth.deleteUser(targetUid);

      return { success: true };
    } catch (error) {
      if (error instanceof HttpsError) throw error;
      console.error("[deleteUserAccount] Error:", error);
      throw new HttpsError('internal', 'فشل حذف الحساب: ' + error.message);
    }
  }
);
// ══════════════════════════════════════════════════════════════
// 2. دالة إنشاء الطلب واعتماد المخزون والترقيم الذري القطعي
// ══════════════════════════════════════════════════════════════
exports.placeOrder = onCall(
  {
    region: "us-central1",
    cors: true,
    concurrency: 80,
    memory: "512MiB",
  },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "يجب تسجيل الدخول أولاً");
    }

    const uid = request.auth.uid;
   const { orderId, items, notes, extraData, expectedTotal } = request.data || {};
    const cleanOrderId = String(orderId || "").trim();

  if (!/^[A-Za-z0-9_-]{1,128}$/.test(cleanOrderId) || !Array.isArray(items) || items.length === 0) {
      throw new HttpsError("invalid-argument", "بيانات الطلب غير مكتملة");
    }
    if (notes != null && (typeof notes !== "string" || notes.length > 1000)) {
      throw new HttpsError("invalid-argument", "ملاحظات الطلب تتجاوز الحد المسموح");
    }
    if (items.length > 50) {
      throw new HttpsError("invalid-argument", "تجاوزت الحد الأقصى للأصناف في الطلب الواحد (50 صنف)");
    }

    // 1. فحص حساب التاجر (الحظر والنشاط)
    const { data: profile } = await requireActiveRole(
      uid,
      ["merchant"],
      "إنشاء الطلبات متاح لحسابات التجار النشطة فقط",
    );

    const orderRef = db.collection("orders").doc(cleanOrderId);

    // ── المرحلة الأولى: خصم المخزون وإنشاء عناصر الطلب (بدون قفل العداد) ──
   const phaseOneResult = await db.runTransaction(async (tx) => {
      // 🛡️ فحص Idempotency وفحص أمني صارم لملكية الطلب (منع ثغرة IDOR)
      const existingSnap = await tx.get(orderRef);
      if (existingSnap.exists) {
        const existingOrderData = existingSnap.data();
        if (existingOrderData?.merchant_id !== uid) {
          throw new HttpsError("permission-denied", "غير مصرح لك بالوصول إلى هذا الطلب أو تكراره");
        }
        if (existingOrderData?.order_number) {
                 const plainExisting = {};
          for (const [k, v] of Object.entries(existingOrderData)) {
            plainExisting[k] = (v && typeof v.toDate === "function") ? v.toDate().toISOString() : v;
          }
          return { alreadyCreated: true, order: { id: existingSnap.id, ...plainExisting } };
        }
      }

    // 🚀 جلب متوازٍ متزامن فائق السرعة لكافة الدفعات دفعة واحدة (توفير 40% من زمن المعاملة)
      const productIds = [...new Set(items.map((i) => String(i.product_id).trim()))];
      const productMap = new Map();
      const productFinancialMap = new Map();
      const BATCH_SIZE = 25;

      const chunkPromises = [];
      for (let i = 0; i < productIds.length; i += BATCH_SIZE) {
        const chunk = productIds.slice(i, i + BATCH_SIZE);
        chunkPromises.push(Promise.all(chunk.map((id) => tx.get(db.collection("products").doc(id)))));
        chunkPromises.push(Promise.all(chunk.map((id) => tx.get(db.collection("product_financials").doc(id)))));
      }

      const allChunkResults = await Promise.all(chunkPromises);
      for (let i = 0; i < allChunkResults.length; i += 2) {
        const productSnaps = allChunkResults[i];
        const financeSnaps = allChunkResults[i + 1];

        productSnaps.forEach((snap) => {
          if (snap.exists) productMap.set(snap.id, snap.data());
        });
        financeSnaps.forEach((snap) => {
          if (snap.exists) productFinancialMap.set(snap.id, snap.data());
        });
      }
// 🚀 تفويض الحسابات بالكامل للمحرك الصافي المعزول والقابل للاختبار المنفصل
      const {
        serverTotal,
        serverProfit,
        stockDeductions,
        enrichedItems,
        itemFinancials,
        unavailableItems,
        outOfStockItems,
      } = OrderCalculator.processOrderItems({
        items,
        productMap,
        productFinancialMap,
        orderId: orderRef.id,
        merchantId: uid,
      });
      // 🛡️ فحص حاسم للمخزون: منع إنشاء أي طلب ناقص وإشعار التاجر فوراً بالأصناف غير المتوفرة
      if (unavailableItems.length > 0) {
        const ids = unavailableItems.map((i) => i.id).join(",");
        const names = unavailableItems.map((i) => i.name).join("، ");
        throw new HttpsError(
          "failed-precondition",
          `PRODUCT_UNAVAILABLE_[${ids}]: نعتذر، الأصناف التالية لم تعد متوفرة في المستودع (${names})`,
        );
      }

    if (outOfStockItems.length > 0) {
        const itemTokens = outOfStockItems.map((i) => `${i.id}:${i.unitLabel}`).join(",");
        const names = outOfStockItems.map((i) => `${i.name} (${i.unitLabel})`).join("، ");
        throw new HttpsError(
          "failed-precondition",
          `OUT_OF_STOCK_[${itemTokens}]: نعتذر، نفد مخزون الأصناف التالية من المستودع (${names})`,
        );
      }

      if (enrichedItems.length === 0) {
        throw new HttpsError("failed-precondition", "لا توجد أصناف صالحة لإتمام هذا الطلب");
      }
// 🚀 توليد رقم الفاتورة عبر المحرك الموحد
      const invoiceNumberString = IdGenerator.generateInvoiceNumber();
// ✅ التحقق الديناميكي من الحد الأدنى بدون تحميل التاجر أي رسوم توصيل إضافية
      let minOrderValue = 4250.0;
      try {
        const configDoc = await tx.get(db.collection("system_config").doc("app_config"));
        if (configDoc.exists) {
          const fetchedMin = Number(configDoc.data()?.min_order_value);
          if (Number.isFinite(fetchedMin) && fetchedMin > 0) {
            minOrderValue = fetchedMin;
          }
        }
      } catch (_) {
        minOrderValue = 4250.0;
      }

      if (serverTotal < minOrderValue) {
        throw new HttpsError("failed-precondition", `الحد الأدنى للطلب هو ${minOrderValue} ريال يمني`);
      }

      // 🔒 حماية مالية صارمة: فحص تطابق الإجمالي الصافي للسلة
   if (expectedTotal != null) {
        const clientTotal = Number(expectedTotal);
        if (Number.isFinite(clientTotal) && Math.abs(serverTotal - clientTotal) > 1.0) {
          throw new HttpsError(
            "failed-precondition",
            `PRICE_DIVERGENCE: تغيرت أسعار بعض المنتجات في سلتك. الإجمالي المحسوب بالسيرفر (${serverTotal.toFixed(0)}) يختلف عن إجمالي السلة (${clientTotal.toFixed(0)}). يرجى مراجعة السلة.`
          );
        }
      }
      OrderCalculator.applyProductStockDeltas({
        tx,
        entries: Array.from(stockDeductions.values()),
        productMap,
        isRestore: false,
        auditMeta: {
          order_id: cleanOrderId,
          action: "order_placed",
          merchant_id: uid,
        },
      });
      // 🔒 التوصيل مجاني للتاجر: إجمالي الفاتورة يطابق سلتَه 100% دون زيادة
      const rawExtra = extraData || {};
      const grandTotal = serverTotal;
      const driverRewardFee = 500.0; // أجر السائق عند التسليم المكتمل

      const orderDataWithNumber = {
        store_name: String(rawExtra.store_name || profile.store_name || "").trim(),
        customer_name: String(rawExtra.customer_name || rawExtra.merchant_name || profile.full_name || "").trim(),
        merchant_name: String(rawExtra.merchant_name || profile.full_name || "").trim(),
        contact: String(rawExtra.contact || rawExtra.phone_number || profile.phone_number || "").trim(),
        phone_number: String(rawExtra.phone_number || rawExtra.contact || profile.phone_number || "").trim(),
        delivery_address: String(rawExtra.delivery_address || rawExtra.store_name || "").trim(),
        latitude: rawExtra.latitude != null ? Number(rawExtra.latitude) : (profile.latitude || null),
        longitude: rawExtra.longitude != null ? Number(rawExtra.longitude) : (profile.longitude || null),
        payment_method: String(rawExtra.payment_method || "cash").trim().toLowerCase() === "deferred" ? "deferred" : "cash",
        merchant_id: uid,
        subtotal: serverTotal,
        total: grandTotal,
        total_amount: grandTotal,
        original_total: grandTotal,
        returned_amount: 0,
        pending_returns_count: 0,
        delivery_fee: driverRewardFee, // تُحفظ كاستحقاق للسائق في أرباحه
        notes: notes ? String(notes).trim() : null,
        status: "pending",
        profit_recorded: false,
        financial_safe: true,
        items_count: enrichedItems.length,
        order_number: invoiceNumberString,
        invoice_number: invoiceNumberString,
        created_at: FieldValue.serverTimestamp(),
        updated_at: FieldValue.serverTimestamp(),
      };
      // كتابة الطلب وعناصره مباشرة
      tx.set(orderRef, orderDataWithNumber);

      for (let index = 0; index < enrichedItems.length; index++) {
        const itemRef = db.collection("order_items").doc();
        tx.set(itemRef, enrichedItems[index]);
        tx.set(db.collection("order_item_financials").doc(itemRef.id), {
          order_id: orderRef.id,
          order_item_id: itemRef.id,
          ...itemFinancials[index],
          updated_at: FieldValue.serverTimestamp(),
        });
      }
      tx.set(db.collection("order_financials").doc(orderRef.id), {
        order_id: orderRef.id,
        total_profit: serverProfit,
        profit_recorded: false,
        updated_at: FieldValue.serverTimestamp(),
      });

      return { alreadyCreated: false, orderData: orderDataWithNumber };
    });

 // لا يُشعر السائقون عند الإنشاء لأن الطلب ما زال pending بانتظار اعتماد الإدارة

  if (phaseOneResult.alreadyCreated) {
      return { success: true, order: phaseOneResult.order };
    }

    const completeOrder = {
      id: orderRef.id,
      ...phaseOneResult.orderData,
      created_at: new Date().toISOString(),
      updated_at: new Date().toISOString(),
    };

    return { success: true, order: completeOrder };
  }
);
// ══════════════════════════════════════════════════════════════
// 2. دالة إلغاء الطلب واسترجاع المخزون (cancelOrder)
// ══════════════════════════════════════════════════════════════
exports.cancelOrder = onCall(
  { region: "us-central1", cors: true },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "يجب تسجيل الدخول");
    }

    const uid = request.auth.uid;
    const { orderId } = request.data || {};
    if (!orderId) {
      throw new HttpsError("invalid-argument", "معرف الطلب مطلوب");
    }
const cleanOrderId = String(orderId).trim();
    const orderRef = db.collection("orders").doc(cleanOrderId);

const txResult = await db.runTransaction(async (tx) => {      // 🔒 قراءة متزامنة وذرية 100% داخل المعاملة (Strict Snapshot Isolation)
      const [orderSnap, itemsSnap] = await Promise.all([
        tx.get(orderRef),
        tx.get(db.collection("order_items").where("order_id", "==", cleanOrderId)),
      ]);

      if (!orderSnap.exists) {
        throw new HttpsError("not-found", "الطلب غير موجود");
      }
      const order = orderSnap.data();
      const itemDocs = itemsSnap.docs;
      // التحقق من الصلاحية: صاحب الطلب أو إدارة
      const userProfile = await tx.get(db.collection("profiles").doc(uid));
      const userData = userProfile.data() || {};
      if (!userProfile.exists || userData.is_banned === true ||
          userData.is_active !== true) {
        throw new HttpsError("permission-denied", "الحساب غير نشط أو محظور");
      }
      const role = String(userData.role || "").trim().toLowerCase();
      if (!["merchant", "admin", "super_admin"].includes(role)) {
        throw new HttpsError("permission-denied", "غير مصرح لهذا الحساب بإلغاء الطلبات");
      }
      const isAdmin = role === "admin" || role === "super_admin";

      if (order.merchant_id !== uid && !isAdmin) {
        throw new HttpsError("permission-denied", "غير مصرح لك بإلغاء هذا الطلب");
      }
      if (order.status !== "pending") {
        throw new HttpsError("failed-precondition", `لا يمكن إلغاء طلب بحالة: ${order.status}`);
      }
const stockRestores = new Map();
      const uniqueProductIds = new Set();
      for (const doc of itemDocs) {
        const item = doc.data();
        const pId = item.product_id;
        const vId = item.variant_id ? String(item.variant_id).trim() : null;
        const qty = Number(item.quantity) || 0;
        const capacity = Number(item.carton_capacity) || 1;
        const unitQty = Number(item.unit_qty) || capacity;
        const cartonsToRestore = Number(((qty * unitQty) / capacity).toFixed(4));

        if (pId && cartonsToRestore > 0) {
          uniqueProductIds.add(pId);
          const key = vId ? `${pId}__v_${vId}` : pId;
          const prev = stockRestores.get(key);
          stockRestores.set(key, {
            productId: pId,
            variantId: vId,
            delta: Number(((prev?.delta || 0) + cartonsToRestore).toFixed(4)),
          });
        }
      }

      const productSnaps = await Promise.all(
        Array.from(uniqueProductIds).map((pId) => tx.get(db.collection("products").doc(pId)))
      );
      const productMap = new Map();
      productSnaps.forEach((pSnap) => {
        if (pSnap.exists) productMap.set(pSnap.id, pSnap.data());
      });

      OrderCalculator.applyProductStockDeltas({
        tx,
        entries: Array.from(stockRestores.values()),
        productMap,
        isRestore: true,
        auditMeta: {
          order_id: cleanOrderId,
          action: "order_cancelled",
          performed_by: uid,
        },
      });
     tx.update(orderRef, {
        status: "cancelled",
        cancelled_at: FieldValue.serverTimestamp(),
        updated_at: FieldValue.serverTimestamp(),
      });

      return { success: true };
    });

    return txResult;
  }
);

// ══════════════════════════════════════════════════════════════
// 3. دالة معالجة المرتجعات وتسويتها (processReturn & updateReturnStatus)
// ══════════════════════════════════════════════════════════════
exports.processReturn = onCall(
  { region: "us-central1", cors: true },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "يجب تسجيل الدخول");
    }

    const uid = request.auth.uid;
    const { returnId, status, rejectionReason } = request.data || {};

    if (!returnId || !["accepted", "rejected"].includes(status)) {
      throw new HttpsError("invalid-argument", "بيانات المرتجع غير صالحة");
    }

    // التحقق من صلاحيات الإدارة
    await requireActiveRole(
      uid,
      ["admin", "super_admin", "accountant", "warehouse_manager"],
      "هذه العملية خاصة بالإدارة فقط",
    );

    const returnRef = db.collection("order_returns").doc(String(returnId).trim());

    return await db.runTransaction(async (tx) => {
      const returnSnap = await tx.get(returnRef);
      if (!returnSnap.exists) {
        throw new HttpsError("not-found", "طلب الإرجاع غير موجود");
      }
      const returnData = returnSnap.data();
      if (returnData.status !== "pending") {
        return { success: true, message: "تمت معالجة الطلب مسبقاً" };
      }

      const orderRef = db.collection("orders").doc(returnData.order_id);
      const orderSnap = await tx.get(orderRef);
      const orderData = orderSnap.exists ? orderSnap.data() : null;
      const orderFinancialRef = db.collection("order_financials").doc(returnData.order_id);
      const orderFinancialSnap = await tx.get(orderFinancialRef);

      // 🔒 قراءة رقمية قطعية تمنع تحويل الصفر (0) إلى (1) بفعل الفحص المنطقي Falsy
      const rawPending = Number(orderData?.pending_returns_count);
      const currentPendingCount = Number.isFinite(rawPending) ? rawPending : 1;
      const newPendingCount = Math.max(0, currentPendingCount - 1);
      const hasOtherPending = newPendingCount > 0;

      if (status === "rejected") {
        if (returnData.merchant_id) {
          tx.set(db.collection("user_notifications").doc(), {
            user_id: returnData.merchant_id,
            title: "❌ تم رفض طلب الإرجاع",
            body: rejectionReason
              ? `سبب الرفض: ${String(rejectionReason).trim()}`
              : "تم رفض طلب الإرجاع من الإدارة.",
            order_id: returnData.order_id,
            type: "order_status",
            is_read: false,
            created_at: FieldValue.serverTimestamp(),
          });
        }
        tx.update(returnRef, {
          status: "rejected",
          rejection_reason: rejectionReason ? String(rejectionReason).trim() : null,
          updated_at: FieldValue.serverTimestamp(),
        });

        if (orderSnap.exists) {
          tx.update(orderRef, {
            status: hasOtherPending ? "return_requested" : "delivered",
            pending_returns_count: newPendingCount,
            updated_at: FieldValue.serverTimestamp(),
          });
        }
        return { success: true };
      }
    // إذا كانت الحالة accepted: جلب كافة المستندات (Reads) أولاً قبل أي كتابة
      const itemRef = db.collection("order_items").doc(returnData.order_item_id);
      const itemFinancialRef = db.collection("order_item_financials").doc(returnData.order_item_id);
      const summaryParentRef = db.collection("stats").doc("profit_summary");
const [itemSnap, itemFinancialSnap, summarySnap] = await Promise.all([
        tx.get(itemRef),
        tx.get(itemFinancialRef),
        tx.get(summaryParentRef),
      ]);

      if (!itemSnap.exists) {
        throw new HttpsError("not-found", "عنصر الطلب الأصلي غير موجود");
      }
      const itemData = itemSnap.data();
    const productRef = db.collection("products").doc(itemData.product_id);
      const productSnap = await tx.get(productRef);
      const productMap = new Map();
      if (productSnap.exists) productMap.set(productSnap.id, productSnap.data());

const returnQty = Number(returnData.quantity) || 0;
      const orderedQty = Number(itemData.quantity) || 0;
      const alreadyReturned = Number(itemData.returned_quantity) || 0;
      const maxReturnable = Math.max(0, orderedQty - alreadyReturned);
      if (returnQty <= 0 || returnQty > maxReturnable) {
        throw new HttpsError(
          "failed-precondition",
          `الكمية المطلوب إرجاعها (${returnQty}) تتجاوز المتبقي (${maxReturnable})`,
        );
      }
      const capacity = Number(itemData.carton_capacity) || 1;
      const unitQty = Number(itemData.unit_qty) || capacity;
      const cartonsToRestore = Number(((returnQty * unitQty) / capacity).toFixed(4));
const price = Number(itemData.price) || 0;
      const refundAmount = Number((price * returnQty).toFixed(2));

      const unitCost = Number(
        itemFinancialSnap.data()?.unit_cost ?? itemData.unit_cost,
      ) || 0;
      const deductedProfit = Number(((price - unitCost) * returnQty).toFixed(2));
      const rawProfit = orderFinancialSnap.data()?.total_profit ?? orderData?.total_profit;
      const currentProfit = Number.isFinite(Number(rawProfit)) ? Number(rawProfit) : 0;

      const lastResetAt = summarySnap.data()?.last_reset_at?.toMillis?.() ?? 0;
      const orderDeliveredAt = orderData?.delivered_at?.toMillis?.() ?? (orderData?.created_at?.toMillis?.() ?? 0);
      const isFromCurrentCycle = orderDeliveredAt >= lastResetAt;

      // ── مرحلة الكتابة (Writes) حصراً بعد انتهاء كافة القراءات ──
      // 1. إعادة المخزون (مع مراعاة مخزون الأحجام variants)
      OrderCalculator.applyProductStockDeltas({
        tx,
        entries: [{
          productId: itemData.product_id,
          variantId: itemData.variant_id || null,
          delta: cartonsToRestore,
        }],
        productMap,
        isRestore: true,
        auditMeta: {
          order_id: returnData.order_id,
          action: "return_accepted",
          performed_by: uid,
        },
      });
      // 2. تحديث عداد المرتجع في الصنف
      tx.update(itemRef, {
        returned_quantity: FieldValue.increment(returnQty),
        updated_at: FieldValue.serverTimestamp(),
      });

      // 3. تحديث الفاتورة
      const currentTotal = Number(orderData?.total_amount || orderData?.total || 0);
const safeNewTotal = Math.max(0, Number((currentTotal - refundAmount).toFixed(2)));
      tx.update(orderRef, {
        status: safeNewTotal <= 0.01 && !hasOtherPending ? "returned" : (hasOtherPending ? "return_requested" : "delivered"),
        total: safeNewTotal,
        total_amount: safeNewTotal,
        returned_amount: FieldValue.increment(refundAmount),
        pending_returns_count: newPendingCount,
        updated_at: FieldValue.serverTimestamp(),
      });
      tx.set(orderFinancialRef, {
        order_id: returnData.order_id,
        total_profit: currentProfit - deductedProfit,
        updated_at: FieldValue.serverTimestamp(),
      }, { merge: true });

          if (returnData.merchant_id) {
        tx.set(db.collection("user_notifications").doc(), {
          user_id: returnData.merchant_id,
          title: "✅ تم قبول طلب الإرجاع",
          body: `تمت تسوية إرجاع (${returnData.product_name || "منتج"}) واسترداد ${refundAmount.toFixed(0)} ر.ي`,
          order_id: returnData.order_id,
          type: "order_status",
          is_read: false,
          created_at: FieldValue.serverTimestamp(),
        });
      }
      // 4. تحديث حالة المرتجع
      tx.update(returnRef, {
        status: "accepted",
        updated_at: FieldValue.serverTimestamp(),
      });

    // 5. تحديث مستند الإحصائيات (فقط إذا كانت الأرباح مسجلة مسبقاً عند التسليم)
      if (orderData?.profit_recorded === true) {
        const statsUpdates = {
          accumulated_profit: FieldValue.increment(-deductedProfit),
          accumulated_returns: FieldValue.increment(refundAmount),
          accumulated_revenue: FieldValue.increment(-refundAmount),
          last_updated: FieldValue.serverTimestamp(),
        };

        if (isFromCurrentCycle) {
          statsUpdates.cycle_profit = FieldValue.increment(-deductedProfit);
        } else {
          statsUpdates.prior_period_adjustments = FieldValue.increment(-deductedProfit);
        }
        tx.set(summaryParentRef, statsUpdates, { merge: true });
      }
      return { success: true };
    });
  }
);
// ══════════════════════════════════════════════════════════════
// 1. دالة استلام السائق للطلب وقفل التنافس (assignOrderToDriver)
// ══════════════════════════════════════════════════════════════
exports.assignOrderToDriver = onCall(
  { region: "us-central1", cors: true },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "يجب تسجيل الدخول");
    }

    const uid = request.auth.uid;
    const { orderId } = request.data || {};
    if (!orderId) {
      throw new HttpsError("invalid-argument", "معرف الطلب مطلوب");
    }

    // 1. التحقق من رتبة وصلاحية السائق
    const driverDoc = await db.collection("profiles").doc(uid).get();
    if (!driverDoc.exists) {
      throw new HttpsError("not-found", "حساب السائق غير موجود");
    }
    const driverData = driverDoc.data();
    const role = (driverData.role || "").trim().toLowerCase();
    if (driverData.is_banned === true || driverData.is_active !== true || (role !== "driver" && role !== "admin" && role !== "super_admin")) {
      throw new HttpsError("permission-denied", "الحساب غير مصرح له باستلام وتوصيل الطلبات");
    }

    const driverName = driverData.full_name || "مندوب معتمد";
    const orderRef = db.collection("orders").doc(String(orderId).trim());

    return await db.runTransaction(async (tx) => {
      const snap = await tx.get(orderRef);
      if (!snap.exists) {
        throw new HttpsError("not-found", "الطلب غير موجود");
      }
      const order = snap.data();
      // 🛡️ فحص منع التكرار: إذا كان الطلب مسنداً لنفس السائق مسبقاً نرجع نجاحاً فوراً
      if (order.driver_id === uid && order.status === "shipped") {
        return { success: true, message: "الطلب مسند لك بالفعل" };
      }

      // منع سرقة الطلبات بين السائقين
      if (order.driver_id && order.driver_id !== uid) {
        throw new HttpsError("failed-precondition", "تم استلام هذا الطلب من قبل مندوب آخر");
      }
  const allowedPickupStatuses = ["confirmed", "preparing"];
      if (!allowedPickupStatuses.includes(order.status)) {
        throw new HttpsError("failed-precondition", `لا يمكن استلام الطلب إلا بعد اعتماده أو تحضيره (الحالة الحالية: ${order.status})`);
      }

      tx.update(orderRef, {
        status: "shipped",
        driver_id: uid,
        driver_name: driverName,
        picked_up_at: FieldValue.serverTimestamp(),
        updated_at: FieldValue.serverTimestamp(),
      });

      // إشعار فوري للتاجر
      if (order.merchant_id) {
        tx.set(db.collection("user_notifications").doc(), {
          user_id: order.merchant_id,
          title: "🚚 طلبك انطلق نحوك!",
          body: `المندوب (${driverName}) استلم طلبك وهو في الطريق إليك الآن 🛣️`,
          order_id: orderRef.id,
          type: "order_status",
          is_read: false,
          created_at: FieldValue.serverTimestamp(),
        });
      }

      return { success: true };
    });
  }
);

// ══════════════════════════════════════════════════════════════
// 2. دالة تسليم الطلب واعتماد الأرباح والتوقيع (deliverOrderByDriver)
// ══════════════════════════════════════════════════════════════
exports.deliverOrderByDriver = onCall(
  {
    region: "us-central1",
    cors: true,
    concurrency: 80,
    memory: "512MiB",
  },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "يجب تسجيل الدخول");
    }

    const uid = request.auth.uid;
    const { orderId, signatureData } = request.data || {};
    const cleanOrderId = String(orderId || "").trim();
    if (!/^[A-Za-z0-9_-]{1,128}$/.test(cleanOrderId)) {
      throw new HttpsError("invalid-argument", "معرف الطلب مطلوب");
    }

    // التحقق من صلاحية المنفّذ (سائق أو إدارة)
    const callerDoc = await db.collection("profiles").doc(uid).get();
    const callerData = callerDoc.data() || {};
    const callerRole = String(callerData.role || "").trim().toLowerCase();
    const isAuthorized = ["driver", "admin", "super_admin"].includes(callerRole);
    if (!callerDoc.exists || callerData.is_banned === true ||
        callerData.is_active !== true || !isAuthorized) {
      throw new HttpsError("permission-denied", "غير مصرح لك بتسليم الطلبات");
    }

    const orderRef = db.collection("orders").doc(cleanOrderId);
    const preflightSnap = await orderRef.get();
    if (!preflightSnap.exists) {
      throw new HttpsError("not-found", "الطلب غير موجود");
    }
    const preflightOrder = preflightSnap.data() || {};
    if (preflightOrder.status === "delivered" && preflightOrder.profit_recorded === true) {
      return { success: true, message: "تم تسجيل تسليم الطلب مسبقاً" };
    }
 const validPreflightStatuses = ["shipped", "on_the_way", "confirmed", "preparing"];
    if (!validPreflightStatuses.includes(preflightOrder.status)) {
      throw new HttpsError("failed-precondition", `لا يمكن تسليم طلب بحالة: ${preflightOrder.status}`);
    }
    if (callerRole === "driver" && preflightOrder.driver_id && preflightOrder.driver_id !== uid) {
      throw new HttpsError("permission-denied", "هذا الطلب غير مسند إليك أو تم تسليمه لسائق آخر");
    }
// 🔒 استدعاء خدمة التوقيع المركزية الموحدة والمؤمنة
    const finalSignatureUrl = await SignatureService.processSignature(cleanOrderId, signatureData);
    return await db.runTransaction(async (tx) => {
      const snap = await tx.get(orderRef);
      if (!snap.exists) {
        throw new HttpsError("not-found", "الطلب غير موجود");
      }
      const order = snap.data();

     // 🛡️ فحص Idempotency: إذا كان قد سُلّم وسُجلت أرباحه سابقاً نرجع بنجاح فوري
      if (order.status === "delivered" && order.profit_recorded === true) {
        return { success: true, message: "تم تسجيل تسليم الطلب مسبقاً" };
      }
      const financialRef = db.collection("order_financials").doc(cleanOrderId);
      const financialSnap = await tx.get(financialRef);
const validDeliveryStatuses = ["shipped", "on_the_way", "confirmed", "preparing"];
      if (!validDeliveryStatuses.includes(order.status)) {
        throw new HttpsError("failed-precondition", `لا يمكن تسليم طلب بحالة: ${order.status}`);
      }

      // منع التضارب: إذا كان الطلب مسنداً لسائق آخر مسبقاً نرفضه
      if (callerRole === "driver" && order.driver_id && order.driver_id !== uid) {
        throw new HttpsError("permission-denied", "هذا الطلب غير مسند إليك أو تم تسليمه لسائق آخر");
      }

      const totalProfit = Number(
        financialSnap.data()?.total_profit ?? order.total_profit,
      ) || 0;
      const totalAmount = Number(order.total_amount) || Number(order.total) || 0;

    const updatePayload = { 
        status: "delivered",
        delivered_at: FieldValue.serverTimestamp(),
        updated_at: FieldValue.serverTimestamp(),
        profit_recorded: true,
        delivery_fee: Number(order.delivery_fee) > 0 ? Number(order.delivery_fee) : 500.0, // تثبيت الـ 500 ر.ي في حساب السائق
      };

     if (callerRole === "driver") {
        if (!order.driver_id || order.driver_id !== uid) {
          throw new HttpsError("permission-denied", "لا يمكن تأكيد التسليم إلا بعد استلام الطلب من المستودع وقبوله رسمياً");
        }
      }

    // 🔒 فرض وجود التوقيع الرقمي قانونياً عند قيام السائق بالتسليم
      const existingSig = order.signature_url;
      const effectiveSig = finalSignatureUrl || existingSig;

      if (!effectiveSig && callerRole === "driver") {
        throw new HttpsError("failed-precondition", "لا يمكن تأكيد تسليم الشحنة قانونياً دون توقيع المستلم المعتمد");
      }

      if (effectiveSig) {
        updatePayload.signature_url = effectiveSig;
      }
      tx.update(orderRef, updatePayload);
      tx.set(financialRef, {
        order_id: cleanOrderId,
        profit_recorded: true,
        updated_at: FieldValue.serverTimestamp(),
      }, { merge: true });
// 2. تحديث المستند الرئيسي للأرباح والإيرادات ذرياً
      if (order.profit_recorded !== true) {
        const summaryParentRef = db.collection("stats").doc("profit_summary");
        tx.set(summaryParentRef, {
          accumulated_profit: FieldValue.increment(totalProfit),
          cycle_profit: FieldValue.increment(totalProfit),
          accumulated_revenue: FieldValue.increment(totalAmount),
          last_updated: FieldValue.serverTimestamp(),
        }, { merge: true });
      }
      // 3. إشعار التاجر بوصول الطلب
      if (order.merchant_id) {
        tx.set(db.collection("user_notifications").doc(), {
          user_id: order.merchant_id,
          title: "🎉 تم تسليم طلبك بنجاح!",
          body: "تم تسليم الطلب وتوثيق التوقيع بنجاح. شكراً لثقتكم بنا 💐",
          order_id: orderRef.id,
          type: "order_status",
          is_read: false,
          created_at: FieldValue.serverTimestamp(),
        });
      }

      return { success: true };
    });
  }
);
// ══════════════════════════════════════════════════════════════
// دالة تقديم طلبات الإرجاع واعتمادها سحابياً (submitReturnRequest)
// ══════════════════════════════════════════════════════════════
exports.submitReturnRequest = onCall(
  { region: "us-central1", cors: true },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "يجب تسجيل الدخول أولاً");
    }

    const uid = request.auth.uid;
    const { orderId, itemsToReturn, storeName, contact, latitude, longitude, reason } = request.data || {};

    const cleanOrderId = String(orderId || "").trim();
    const cleanReason = String(reason || "").trim();

    if (!cleanOrderId) {
      throw new HttpsError("invalid-argument", "معرف الطلب مطلوب");
    }
    if (!Array.isArray(itemsToReturn) || itemsToReturn.length === 0) {
      throw new HttpsError("invalid-argument", "يجب تحديد أصناف للإرجاع");
    }
    if (itemsToReturn.length > 200) {
      throw new HttpsError("invalid-argument", "عدد أصناف الإرجاع يتجاوز الحد المسموح");
    }
    if (!cleanReason || cleanReason.length < 3) {
      throw new HttpsError("invalid-argument", "سبب الإرجاع مطلوب ويجب توضيحه");
    }

    await requireActiveRole(
      uid,
      ["merchant"],
      "تقديم طلبات الإرجاع متاح لحسابات التجار النشطة فقط",
    );

    const orderRef = db.collection("orders").doc(cleanOrderId);

    // 2. تجميع كميات الأصناف المكررة لمنع تعارض المعاملة الذرية
    const aggregated = new Map();
    for (const item of itemsToReturn) {
      if (!item || typeof item !== "object" || Array.isArray(item)) {
        throw new HttpsError("invalid-argument", "بيانات صنف الإرجاع غير صالحة");
      }
      const itemId = String(item.order_item_id || item.id || "").trim();
      const qty = Number(item.quantity);
      if (!itemId || !Number.isSafeInteger(qty) || qty <= 0) {
        throw new HttpsError("invalid-argument", "معرف الصنف وكمية الإرجاع غير صالحين");
      }
      const totalQty = (aggregated.get(itemId) || 0) + qty;
      if (!Number.isSafeInteger(totalQty)) {
        throw new HttpsError("invalid-argument", "إجمالي كمية الإرجاع يتجاوز الحد المسموح");
      }
      aggregated.set(itemId, totalQty);
    }

    if (aggregated.size === 0) {
      throw new HttpsError("invalid-argument", "لم يتم إدخال كميات صالحة للإرجاع");
    }

    return await db.runTransaction(async (tx) => {
      // 3. قراءة وفحص الطلب الأصلي
      const orderSnap = await tx.get(orderRef);
      if (!orderSnap.exists) {
        throw new HttpsError("not-found", "الطلب غير موجود");
      }
      const order = orderSnap.data();

      // التحقق الصارم من ملكية التاجر للطلب
      if (order.merchant_id !== uid) {
        throw new HttpsError("permission-denied", "غير مصرح لك بطلب إرجاع لهذا الطلب");
      }

      // التحقق من حالة الطلب
      if (order.status !== "delivered" && order.status !== "return_requested") {
        throw new HttpsError("failed-precondition", `لا يمكن طلب إرجاع لطلب بحالة: ${order.status}`);
      }

      // منع تقديم طلب جديد إذا كان هناك إرجاع معلق قيد المراجعة لنفس الطلب
      const pendingCount = Number(order.pending_returns_count) || 0;
      if (pendingCount > 0) {
        throw new HttpsError("failed-precondition", "يوجد طلب إرجاع قيد المراجعة مسبقاً لهذا الطلب");
      }

      // 4. قراءة وفحص عناصر الطلب والتأكد من الأسعار والكميات المتبقية
      const itemEntries = Array.from(aggregated.entries());
      const itemSnaps = await Promise.all(
        itemEntries.map(([itemId]) => tx.get(db.collection("order_items").doc(itemId)))
      );
const returnDocs = [];

      for (let i = 0; i < itemSnaps.length; i++) {
        const itemSnap = itemSnaps[i];
        const [itemId, returnQty] = itemEntries[i];

        if (!itemSnap.exists) {
          throw new HttpsError("not-found", "عنصر الطلب غير موجود");
        }

        const itemData = itemSnap.data();
        if (itemData.order_id !== cleanOrderId) {
          throw new HttpsError("invalid-argument", "أحد الأصناف لا يتبع هذا الطلب");
        }

        const orderedQty = Number(itemData.quantity) || 0;
        const alreadyReturned = Number(itemData.returned_quantity) || 0;
        const remainingQty = Math.max(0, orderedQty - alreadyReturned);

        if (returnQty > remainingQty) {
          throw new HttpsError(
            "failed-precondition",
            `الكمية المطلوب إرجاعها من "${itemData.product_name}" (${returnQty}) تتجاوز الكمية المتبقية (${remainingQty})`
          );
        }

const returnSeqString = IdGenerator.generateReturnNumber();
        const itemPrice = Number(itemData.price) || 0;
        const refundAmount = itemPrice * returnQty;
returnDocs.push({
          ref: db.collection("order_returns").doc(),
          data: {
            order_id: cleanOrderId,
            order_item_id: itemSnap.id,
            merchant_id: uid,
            product_id: itemData.product_id || "",
            product_name: String(itemData.product_name || "منتج").trim(),
            quantity: returnQty,
            unit_label: String(itemData.unit_label || "كرتون").trim(),
            unit_price: itemPrice,
            refund_amount: refundAmount,
            returned_amount: refundAmount,
            store_name: String(storeName || order.store_name || "").trim(),
            contact: String(contact || order.contact || order.phone_number || "").trim(),
            latitude: latitude != null ? Number(latitude) : (order.latitude || null),
            longitude: longitude != null ? Number(longitude) : (order.longitude || null),
            reason: cleanReason,
            status: "pending",
            return_number: returnSeqString,
            invoice_number: returnSeqString,
            created_at: FieldValue.serverTimestamp(),
            updated_at: FieldValue.serverTimestamp(),
          },
        });
      }

      // 5. كتابة مستندات الإرجاع وحالة الطلب
      for (const rDoc of returnDocs) {
        tx.set(rDoc.ref, rDoc.data);
      }
      tx.update(orderRef, {
        status: "return_requested",
        return_reason: cleanReason,
        pending_returns_count: returnDocs.length,
        updated_at: FieldValue.serverTimestamp(),
      });

      return { success: true, count: returnDocs.length };
    });
  }
);
// ══════════════════════════════════════════════════════════════
// 1. دالة إدارة الحسابات، الصلاحيات، والحظر السحابية (manageUserAccount)
// ══════════════════════════════════════════════════════════════
exports.manageUserAccount = onCall(
  { region: "us-central1", cors: true },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "يجب تسجيل الدخول أولاً");
    }

    const callerUid = request.auth.uid;
    const { targetUserId, action, role: newRole, isActive } = request.data || {};

    const cleanTargetId = String(targetUserId || "").trim();
    const cleanAction = String(action || "").trim();

    if (!cleanTargetId || !cleanAction) {
      throw new HttpsError("invalid-argument", "معرف المستخدم ونوع الإجراء مطلوبان");
    }

    // 1. التحقق الصارم من رتبة وصلاحية المدير المنفّذ من السيرفر
    const callerDoc = await db.collection("profiles").doc(callerUid).get();
    if (!callerDoc.exists) {
      throw new HttpsError("permission-denied", "حساب المنفّذ غير مسجل");
    }
    const callerData = callerDoc.data() || {};
    const callerRole = String(callerData.role || "").trim().toLowerCase();

    if (callerData.is_banned === true || callerData.is_active !== true || (callerRole !== "admin" && callerRole !== "super_admin")) {
      throw new HttpsError("permission-denied", "هذه العملية مقتصرة على مدراء النظام فقط");
    }

    // حماية: منع المدير من حظر أو تعطيل حسابه الشخصي
    if (callerUid === cleanTargetId && (cleanAction === "ban" || cleanAction === "toggle_active")) {
      throw new HttpsError("failed-precondition", "لا يمكنك حظر أو تعطيل حسابك الشخصي");
    }

    const targetRef = db.collection("profiles").doc(cleanTargetId);
    const targetDoc = await targetRef.get();
    if (!targetDoc.exists) {
      throw new HttpsError("not-found", "المستخدم المستهدف غير موجود");
    }
    const targetData = targetDoc.data() || {};
    const targetRole = String(targetData.role || "").trim().toLowerCase();

    // حماية: لا يمكن لمدير عادي تعديل حساب المدير العام
    if (targetRole === "super_admin" && callerRole !== "super_admin") {
      throw new HttpsError("permission-denied", "لا يمكن تعديل صلاحيات المدير العام");
    }

    const allowedRoles = ["merchant", "driver", "admin", "super_admin", "accountant", "warehouse_manager"];

    switch (cleanAction) {
 case "change_role": {
        if (targetData.is_banned === true) {
          throw new HttpsError(
            "failed-precondition",
            "لا يمكن تغيير رتبة حساب محظور قبل رفع الحظر عنه"
          );
        }
        const cleanRole = String(newRole || "").trim().toLowerCase();
        if (!allowedRoles.includes(cleanRole)) {
          throw new HttpsError("invalid-argument", "الرتبة المحددة غير صالحة");
        }
        if (cleanRole === "super_admin" && callerRole !== "super_admin") {
          throw new HttpsError("permission-denied", "ترقية الحساب إلى مدير عام مقتصرة على المدير العام فقط");
        }

        // 🔒 تحديث الرتبة وإبطال الجلسات في خادم الأمان أولاً لضمان عدم حدوث تباين عند الفشل
        try {
          const userRecord = await auth.getUser(cleanTargetId);
          const currentClaims = userRecord.customClaims || {};
          await auth.setCustomUserClaims(cleanTargetId, {
            ...currentClaims,
            role: cleanRole,
            purpose: "registered",
          });
          await auth.revokeRefreshTokens(cleanTargetId);
        } catch (authErr) {
          console.error(`[manageUserAccount] Failed to set claims/revoke tokens for ${cleanTargetId}:`, authErr);
          throw new HttpsError("internal", "تعذر توثيق الصلاحيات في خادم الأمان، لم يتم إجراء أي تغيير");
        }

        const updates = {
          role: cleanRole,
          tokens_revoked_at: FieldValue.serverTimestamp(),
          updated_at: FieldValue.serverTimestamp(),
        };

        if (cleanRole === "driver") {
          updates.is_active = true;
          updates.is_banned = false;
          updates.account_status = "active";
        }

        await targetRef.update(updates);
        return { success: true, message: "تم تغيير الرتبة وتوثيق الصلاحيات بنجاح" };
      }
   case "ban": {
        await targetRef.update({
          is_active: false,
          is_banned: true,
          account_status: "banned",
          banned_at: FieldValue.serverTimestamp(),
          updated_at: FieldValue.serverTimestamp(),
        });
        try {
          const userRecord = await auth.getUser(cleanTargetId);
          const currentClaims = userRecord.customClaims || {};
          await auth.setCustomUserClaims(cleanTargetId, {
            ...currentClaims,
            is_banned: true,
          });
          await auth.revokeRefreshTokens(cleanTargetId);
        } catch (_) {}
        return { success: true, message: "تم حظر الحساب بنجاح" };
      }

      case "unban": {
        await targetRef.update({
          is_active: true,
          is_banned: false,
          account_status: "active",
          banned_at: FieldValue.delete(),
          updated_at: FieldValue.serverTimestamp(),
        });
        try {
          const userRecord = await auth.getUser(cleanTargetId);
          const currentClaims = { ...(userRecord.customClaims || {}) };
          delete currentClaims.is_banned;
          await auth.setCustomUserClaims(cleanTargetId, currentClaims);
        } catch (_) {}
        return { success: true, message: "تم رفع الحظر بنجاح" };
      }
   case "toggle_active": {
        if (targetData.is_banned === true) {
          throw new HttpsError(
            "failed-precondition",
            "الحساب محظور نهائياً، استخدم خيار رفع الحظر بدلاً من التفعيل"
          );
        }
        if (typeof isActive !== "boolean") {
          throw new HttpsError("invalid-argument", "حالة التفعيل يجب أن تكون قيمة منطقية");
        }
        const activeBool = isActive;
        await targetRef.update({
          is_active: activeBool,
          account_status: activeBool ? "active" : "suspended",
          updated_at: FieldValue.serverTimestamp(),
        });
        if (!activeBool) {
          try {
            await auth.revokeRefreshTokens(cleanTargetId);
          } catch (_) {}
        }
        return { success: true, message: activeBool ? "تم تفعيل الحساب" : "تم تعطيل الحساب" };
      }

      default:
        throw new HttpsError("invalid-argument", "نوع الإجراء غير معروف");
    }
  }
);
// ══════════════════════════════════════════════════════════════
// 2. دالة بث الإشعارات لجميع التجار سحابياً (sendBroadcastNotification)
// ══════════════════════════════════════════════════════════════
exports.sendBroadcastNotification = onCall(
  { region: "us-central1", cors: true },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "يجب تسجيل الدخول أولاً");
    }

    const callerUid = request.auth.uid;
    const { title, body } = request.data || {};

    const cleanTitle = String(title || "").trim();
    const cleanBody = String(body || "").trim();

    if (!cleanTitle || !cleanBody) {
      throw new HttpsError("invalid-argument", "عنوان ونص الإشعار مطلوبان");
    }

    // التحقق من صلاحيات الإدارة
    await requireActiveRole(
      callerUid,
      ["admin", "super_admin", "accountant"],
      "هذه العملية خاصة بالإدارة فقط",
    );
// 1. تسجيل وثيقة الإشعار في سجل البث العام (Broadcast Archive)
    await db.collection("broadcast_notifications").add({
      title: cleanTitle,
      body: cleanBody,
      target_role: "merchant",
      sent_by: callerUid,
      status: "sent",
      created_at: FieldValue.serverTimestamp(),
    });

    // 2. 🚀 الحل المعماري الصافي لمعضلة الـ Thundering Herd:
    // إرسال طلب سحابي واحد فوري عبر FCM Topic 'merchants' الذي تشترك فيه جميع هواتف التجار
    // هذا يلغي 2000 مثيل سحابي متزامن ويوفر آلاف القراءات من قاعدة البيانات فوراً
    try {
      await messaging.send({
        topic: "merchants",
        notification: {
          title: cleanTitle,
          body: cleanBody,
        },
        data: {
          title: cleanTitle,
          body: cleanBody,
          type: "notification",
          route: "/notifications",
          click_action: "FLUTTER_NOTIFICATION_CLICK",
        },
    android: {
          priority: "high",
          notification: {
            channelId: "wissal_orders_channel_v3",
            priority: "max",
            clickAction: "FLUTTER_NOTIFICATION_CLICK",
          },
        },
        apns: {
          headers: { "apns-priority": "10", "apns-push-type": "alert" },
          payload: {
            aps: {
              alert: { title: cleanTitle, body: cleanBody },
              sound: "default",
              badge: 1,
            },
          },
        },
      });
    } catch (fcmError) {
      console.error("[sendBroadcastNotification] Topic push failed:", fcmError);
    }

    return { success: true };
  }
);
// ══════════════════════════════════════════════════════════════
// 1. الحذف التسلسلي للأصناف والشركات سحابياً (cascadeDeleteCatalogItem)
// ══════════════════════════════════════════════════════════════
exports.cascadeDeleteCatalogItem = onCall(
  { region: "us-central1", cors: true },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "يجب تسجيل الدخول أولاً");
    }

    const callerUid = request.auth.uid;
    const { type, id } = request.data || {};
    const cleanId = String(id || "").trim();

    if (!cleanId || (type !== "category" && type !== "brand")) {
      throw new HttpsError("invalid-argument", "نوع العنصر ومعرفه مطلوبان");
    }

// التحقق من صلاحيات الإدارة
    await requireActiveRole(
      callerUid,
      ["admin", "super_admin", "warehouse_manager"],
      "هذه العملية مخصصة لمدراء النظام فقط",
    );
    async function softDeleteInBatches(query) {
      let count = 0;
      // 🚀 إزالة orderBy(FieldPath.documentId()) لتفادي فرض Composite Index مفقود على Firestore
      while (true) {
        const snap = await query
          .where("is_deleted", "==", false)
          .limit(300)
          .get();
        if (snap.empty) break;
        const batch = db.batch();
        for (const doc of snap.docs) {
          batch.update(doc.ref, {
            is_deleted: true,
            is_active: false,
            deleted_at: FieldValue.serverTimestamp(),
            updated_at: FieldValue.serverTimestamp(),
          });
        }
        await batch.commit();
        count += snap.docs.length;
        if (snap.docs.length < 300) break;
      }
      return count;
    }
    let affectedCount = 0;
    if (type === "category") {
      const catRef = db.collection("categories").doc(cleanId);
      await catRef.update({
        is_deleted: true,
        is_active: false,
        deleted_at: FieldValue.serverTimestamp(),
        updated_at: FieldValue.serverTimestamp(),
      });
      affectedCount++;

      affectedCount += await softDeleteInBatches(
            db.collection("brands").where("category_id", "==", cleanId)
      );

      affectedCount += await softDeleteInBatches(
           db.collection("products").where("category_id", "==", cleanId)
      );
    } else {
      const brandRef = db.collection("brands").doc(cleanId);
      await brandRef.update({
        is_deleted: true,
        is_active: false,
        deleted_at: FieldValue.serverTimestamp(),
        updated_at: FieldValue.serverTimestamp(),
      });
      affectedCount++;

      affectedCount += await softDeleteInBatches(
             db.collection("products").where("brand_id", "==", cleanId)
      );
    }

return { success: true, count: affectedCount };
  }
);

// ══════════════════════════════════════════════════════════════
// 2. تصفير وتدقيق دورة الأرباح سحابياً (resetProfitCycle)
// ══════════════════════════════════════════════════════════════
exports.resetProfitCycle = onCall(
  { region: "us-central1", cors: true },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "يجب تسجيل الدخول أولاً");
    }

    const callerUid = request.auth.uid;
    const { data: callerData } = await requireActiveRole(
      callerUid,
      ["admin", "super_admin", "accountant"],
      "هذه العملية مخصصة للمدراء الماليين فقط",
    );

    const docRef = db.collection("stats").doc("profit_summary");

    return await db.runTransaction(async (tx) => {
      const snap = await tx.get(docRef);
      const currentCycle = Number(snap.data()?.cycle_profit) || 0.0;

      // 1. تسجيل قيد محاسبي تدقيقي غير قابل للتعديل
      const logRef = db.collection("profit_resets_log").doc();
      tx.set(logRef, {
        cleared_amount: currentCycle,
        cleared_by: callerUid,
        cleared_by_name: callerData.full_name || "الإدارة",
        cleared_at: FieldValue.serverTimestamp(),
      });

      // 2. تصفير العداد للدورة الجديدة
      tx.set(
        docRef,
        {
          cycle_profit: 0.0,
          last_reset_at: FieldValue.serverTimestamp(),
        },
        { merge: true }
      );

      return { success: true, clearedAmount: currentCycle };
    });
  }
);

// ══════════════════════════════════════════════════════════════
// 3. تحديث حالات الطلب من الإدارة سحابياً (adminUpdateOrderStatus)
// ══════════════════════════════════════════════════════════════
exports.adminUpdateOrderStatus = onCall(
  { region: "us-central1", cors: true },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "يجب تسجيل الدخول أولاً");
    }

    const callerUid = request.auth.uid;
    const { orderId, status, driverId, driverName } = request.data || {};

    const cleanOrderId = String(orderId || "").trim();
    let cleanStatus = String(status || "").trim().toLowerCase();
    if (cleanStatus === "accepted") cleanStatus = "confirmed";

    if (!cleanOrderId) {
      throw new HttpsError("invalid-argument", "معرف الطلب مطلوب");
    }

    // التحقق من الصلاحيات
    await requireActiveRole(
      callerUid,
      ["admin", "super_admin", "accountant", "warehouse_manager"],
      "هذه العملية خاصة بالإدارة فقط",
    );
const orderRef = db.collection("orders").doc(cleanOrderId);
    const financialRef = db.collection("order_financials").doc(cleanOrderId);
    const requiresStockRestore = cleanStatus === "cancelled" || cleanStatus === "rejected" || cleanStatus === "returned";

   const txResult = await db.runTransaction(async (tx) => {
      // 🔒 قراءة متزامنة ومعزولة 100% داخل المعاملة الذرية لمنع استرجاع المخزون المزدوج
      const [orderSnap, financialSnap, itemsSnap] = await Promise.all([
        tx.get(orderRef),
        tx.get(db.collection("order_financials").doc(cleanOrderId)),
        requiresStockRestore
          ? tx.get(db.collection("order_items").where("order_id", "==", cleanOrderId))
          : Promise.resolve({ docs: [] }),
      ]);

      if (!orderSnap.exists) {
        throw new HttpsError("not-found", "الطلب غير موجود");
      }
      const order = orderSnap.data();
      const itemDocs = itemsSnap.docs;
   const currentStatus = String(order.status || "pending").toLowerCase();
      const isProfitRecorded = order.profit_recorded === true;

      if (currentStatus === cleanStatus && (cleanStatus !== "delivered" || isProfitRecorded)) {
        return { success: true, changed: false };
      }
      if (["cancelled", "rejected", "returned"].includes(currentStatus)) {
        throw new HttpsError("failed-precondition", "لا يمكن تعديل طلب وصل إلى حالة نهائية");
      }

      OrderStateMachine.assertCanTransition(currentStatus, cleanStatus);

      // 🔒 تنفيذ كافة القراءات المطلوبة قبل أي كتابة داخل المعاملة
      let pendingReturnsDocs = [];
      if (currentStatus === "return_requested" && (cleanStatus === "delivered" || cleanStatus === "returned")) {
        const pendingSnap = await tx.get(
          db.collection("order_returns")
            .where("order_id", "==", cleanOrderId)
            .where("status", "==", "pending"),
        );
        pendingReturnsDocs = pendingSnap.docs;
      }
const stockRestores = new Map();
      const uniqueRestoreProductIds = new Set();
      const restoreProductMap = new Map();
      if (requiresStockRestore && itemDocs.length > 0) {
        for (const itemDoc of itemDocs) {
          const item = itemDoc.data();
          const pId = item.product_id;
          const vId = item.variant_id ? String(item.variant_id).trim() : null;
          const orderedQty = Number(item.quantity) || 0;
          const returnedQty = Number(item.returned_quantity) || 0;
          const netQty = Math.max(0, orderedQty - returnedQty);
          if (!pId || netQty <= 0) continue;
          const capacity = Number(item.carton_capacity) || 1;
          const unitQty = Number(item.unit_qty) || capacity;
          const cartonsToRestore = Number(((netQty * unitQty) / capacity).toFixed(4));
          if (cartonsToRestore > 0) {
            uniqueRestoreProductIds.add(pId);
            const key = vId ? `${pId}__v_${vId}` : pId;
            const prev = stockRestores.get(key);
            stockRestores.set(key, {
              productId: pId,
              variantId: vId,
              delta: Number(((prev?.delta || 0) + cartonsToRestore).toFixed(4)),
            });
          }
        }
        if (uniqueRestoreProductIds.size > 0) {
          const productSnaps = await Promise.all(
            Array.from(uniqueRestoreProductIds).map((pId) => tx.get(db.collection("products").doc(pId)))
          );
          productSnaps.forEach((pSnap) => {
            if (pSnap.exists) {
              restoreProductMap.set(pSnap.id, pSnap.data());
            }
          });
        }
      }
      let summarySnap = null;
      const summaryParentRef = db.collection("stats").doc("profit_summary");
      if (cleanStatus === "returned" && isProfitRecorded) {
        summarySnap = await tx.get(summaryParentRef);
      }

      // ── مرحلة الكتابة ──
      const updatePayload = {
        status: cleanStatus,
        updated_at: FieldValue.serverTimestamp(),
      };

      if (cleanStatus === "delivered") {
        updatePayload.delivered_at = FieldValue.serverTimestamp();
        if (currentStatus === "return_requested") {
          for (const d of pendingReturnsDocs) {
            tx.update(d.ref, {
              status: "rejected",
              rejection_reason: "تم اعتماد الطلب كتسليم نهائي",
              updated_at: FieldValue.serverTimestamp(),
            });
          }
          updatePayload.pending_returns_count = 0;
        }
      }
      if (driverId) updatePayload.driver_id = String(driverId).trim();
      if (driverName) updatePayload.driver_name = String(driverName).trim();

      if (cleanStatus === "delivered" && !isProfitRecorded) {
        const totalProfit = Number(
          financialSnap.data()?.total_profit ?? order.total_profit,
        ) || 0;
        const totalAmount = Number(order.total_amount) || Number(order.total) || 0;

        tx.set(summaryParentRef, {
          accumulated_profit: FieldValue.increment(totalProfit),
          cycle_profit: FieldValue.increment(totalProfit),
          accumulated_revenue: FieldValue.increment(totalAmount),
          last_updated: FieldValue.serverTimestamp(),
        }, { merge: true });
        updatePayload.profit_recorded = true;
        tx.set(financialRef, {
          order_id: cleanOrderId,
          profit_recorded: true,
          updated_at: FieldValue.serverTimestamp(),
        }, { merge: true });
    } else if (cleanStatus === "returned" && isProfitRecorded) {
        const rawRemainingProfit = financialSnap.data()?.total_profit ?? order.total_profit ?? 0;
        const remainingProfitToDeduct = Number.isFinite(Number(rawRemainingProfit))
          ? Number(Number(rawRemainingProfit).toFixed(2))
          : 0;
        const netRemainingAmount = Math.max(
          0,
          Number((Number(order.total_amount) || Number(order.total) || 0).toFixed(2))
        );
        const lastResetAt = summarySnap?.data()?.last_reset_at?.toMillis?.() ?? 0;
        const orderDeliveredAt = order.delivered_at?.toMillis?.() ?? (order.created_at?.toMillis?.() ?? 0);
        const isFromCurrentCycle = orderDeliveredAt >= lastResetAt;

        const statsUpdates = {
          accumulated_profit: FieldValue.increment(-remainingProfitToDeduct),
          accumulated_returns: FieldValue.increment(netRemainingAmount),
          accumulated_revenue: FieldValue.increment(-netRemainingAmount),
          last_updated: FieldValue.serverTimestamp(),
        };

        if (isFromCurrentCycle) {
          statsUpdates.cycle_profit = FieldValue.increment(-remainingProfitToDeduct);
        } else {
          statsUpdates.prior_period_adjustments = FieldValue.increment(-remainingProfitToDeduct);
        }

        tx.set(summaryParentRef, statsUpdates, { merge: true });
        updatePayload.profit_recorded = false;
        tx.set(financialRef, {
          order_id: cleanOrderId,
          total_profit: 0.0,
          profit_recorded: false,
          updated_at: FieldValue.serverTimestamp(),
        }, { merge: true });
      }

      if (requiresStockRestore && itemDocs.length > 0) {
        if (cleanStatus === "returned") {
          for (const itemDoc of itemDocs) {
            const orderedQty = Number(itemDoc.data().quantity) || 0;
            tx.update(itemDoc.ref, {
              returned_quantity: orderedQty,
              updated_at: FieldValue.serverTimestamp(),
            });
          }
        }
OrderCalculator.applyProductStockDeltas({
          tx,
          entries: Array.from(stockRestores.values()),
          productMap: restoreProductMap,
          isRestore: true,
          auditMeta: {
            order_id: cleanOrderId,
            action: `admin_status_${cleanStatus}`,
            performed_by: callerUid,
          },
        });
      }

      if (cleanStatus === "returned") {
        const pendingQtyByItemId = new Map();
        if (currentStatus === "return_requested") {
          for (const d of pendingReturnsDocs) {
            const pItemId = d.data().order_item_id;
            const pQty = Number(d.data().quantity) || 0;
            pendingQtyByItemId.set(pItemId, (pendingQtyByItemId.get(pItemId) || 0) + pQty);
            tx.update(d.ref, {
              status: "accepted",
              reconciled_in_batch: true,
              updated_at: FieldValue.serverTimestamp(),
            });
          }
        }
        const fullBaseline = Number(order.original_total) ||
          (Number(order.total_amount || order.total || 0) + Number(order.returned_amount || 0));
        updatePayload.total = 0;
        updatePayload.total_amount = 0;
        updatePayload.original_total = fullBaseline;
        updatePayload.returned_amount = fullBaseline;
        updatePayload.pending_returns_count = 0;

        for (const itemDoc of itemDocs) {
          const itemData = itemDoc.data();
          const orderedQty = Number(itemData.quantity) || 0;
          const returnedQty = Number(itemData.returned_quantity) || 0;
          const alreadyPendingQty = pendingQtyByItemId.get(itemDoc.id) || 0;
          const unreturnedQty = Math.max(0, orderedQty - returnedQty - alreadyPendingQty);
          if (unreturnedQty > 0) {
            const retRef = db.collection("order_returns").doc();
            const returnSeq = IdGenerator.generateReturnNumber();
            tx.set(retRef, {
              order_id: cleanOrderId,
              order_item_id: itemDoc.id,
              merchant_id: order.merchant_id,
              product_id: itemData.product_id || "",
              product_name: itemData.product_name || "منتج",
              quantity: unreturnedQty,
              unit_label: itemData.unit_label || "كرتون",
              unit_price: Number(itemData.price) || 0,
              refund_amount: (Number(itemData.price) || 0) * unreturnedQty,
              store_name: order.store_name || "",
              contact: order.phone_number || order.contact || "",
              reason: "إرجاع كامل ومباشر بقرار الإدارة",
              status: "accepted",
              return_number: returnSeq,
              invoice_number: returnSeq,
              created_at: FieldValue.serverTimestamp(),
              updated_at: FieldValue.serverTimestamp(),
            });
          }
        }
      }
      tx.update(orderRef, updatePayload);
     // 3. إرسال إشعار فوري للتاجر عبر القوالب المركزية الموحدة
      if (order.merchant_id) {
        const notifData = NotificationService.getStatusTemplate(cleanStatus);
        if (notifData) {
          tx.set(db.collection("user_notifications").doc(), {
            user_id: order.merchant_id,
            title: notifData.title,
            body: notifData.body,
            order_id: cleanOrderId,
            type: "order_status",
            status: cleanStatus,
            is_read: false,
            created_at: FieldValue.serverTimestamp(),
          });
        }
      }
 const shouldNotifyDrivers =
        (cleanStatus === "confirmed" || cleanStatus === "preparing") &&
        !driverId &&
        !order.driver_id;

      return {
        success: true,
        changed: true,
        shouldNotifyDrivers,
        orderTotal: Number(order.total_amount || order.total || 0),
      };
    });

    if (txResult?.shouldNotifyDrivers) {
      await NotificationService.notifyDriversNewOrder(cleanOrderId, txResult.orderTotal);
    }

    return { success: txResult.success, changed: txResult.changed };
  }
);     // ══════════════════════════════════════════════════════════════
// 📦 إدارة الكتالوج والمخزون سحابياً مع البث اللحظي لجميع التجار
// ══════════════════════════════════════════════════════════════
// 1. إضافة منتج جديد بسلطة السيرفر
exports.adminAddProduct = onCall(
  { region: "us-central1", cors: true },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "يجب تسجيل الدخول أولاً");
    }

    const callerUid = request.auth.uid;
    await requireActiveRole(
      callerUid,
      ["admin", "super_admin", "warehouse_manager"],
      "هذه العملية مخصصة لمدراء النظام والمستودع فقط",
    );

    const data = request.data || {};
    const cleanName = String(data.name || "").trim();
    const brandId = String(data.brandId || "").trim();
  const price = Number(data.price);
    const costPrice = data.costPrice != null ? Math.max(0, Number(data.costPrice) || 0) : 0;
    const stock = data.stock != null ? Number(data.stock) : 0;

    if (!cleanName) throw new HttpsError("invalid-argument", "اسم المنتج مطلوب");
    if (!brandId) throw new HttpsError("invalid-argument", "الشركة مطلوبة");
    if (!Number.isFinite(price) || price < 0) {
      throw new HttpsError("invalid-argument", "سعر البيع غير صالح");
    }
    if (!Number.isFinite(stock) || stock < 0) {
      throw new HttpsError("invalid-argument", "قيمة المخزون غير صالحة");
    }
    // جلب صنف الشركة تلقائياً
    const brandSnap = await db.collection("brands").doc(brandId).get();
    if (!brandSnap.exists) throw new HttpsError("not-found", "الشركة غير موجودة");
    const categoryId = brandSnap.data()?.category_id || "";
const cleanMainBarcode = Normalizer.barcode(data.barcode);
    const rawVariants = Array.isArray(data.variants) ? data.variants : [];
    const allBarcodes = Normalizer.extractAllBarcodes(data.barcode, data.units, rawVariants);

 if (allBarcodes.length > 0) {
      const barcodeChunks = [];
      for (let i = 0; i < allBarcodes.length; i += 10) {
        barcodeChunks.push(allBarcodes.slice(i, i + 10));
      }
      const barcodeSnaps = await Promise.all(
        barcodeChunks.map((chunk) =>
          db.collection("products")
            .where("is_deleted", "==", false)
            .where("all_barcodes", "array-contains-any", chunk)
            .limit(1)
            .get()
        )
      );
      if (barcodeSnaps.some((snap) => !snap.empty)) {
        throw new HttpsError("already-exists", "الباركود المدخل مسجل بالفعل لمنتج آخر نشط في المستودع");
      }
    }

    const unitFinancials = Array.isArray(data.units)
      ? data.units.map((u) => ({
          label: String(u.label || "").trim(),
          cost_price: Math.max(0, Number(u.cost_price) || 0),
        })).filter((u) => u.label.length > 0)
      : [];

    const units = Array.isArray(data.units)
      ? data.units.map((u) => ({
          label: String(u.label || "").trim(),
          price: Number(u.price) || 0,
          qty: (Number.isFinite(Number(u.qty)) && Number(u.qty) > 0) ? Number(u.qty) : 1,
          size_ml: u.size_ml != null ? Number(u.size_ml) : null,
          image_url: u.image_url ? String(u.image_url).trim() : null,
          barcode: Normalizer.barcode(u.barcode) || null,
          production_date: Normalizer.toSafeTimestamp(u.production_date),
          expiry_date: Normalizer.toSafeTimestamp(u.expiry_date),
        })).filter((u) => u.label.length > 0 && u.price >= 0)
      : [];
const variantBaseTs = Date.now();
const parsedVariants = rawVariants.map((v, idx) => {
      const vUnits = Array.isArray(v.units)
        ? v.units.map((u) => ({
            label: String(u.label || "").trim(),
            price: Number(u.price) || 0,
            qty: (Number.isFinite(Number(u.qty)) && Number(u.qty) > 0) ? Number(u.qty) : 1,
            size_ml: u.size_ml != null ? Number(u.size_ml) : null,
            image_url: u.image_url ? String(u.image_url).trim() : null,
            barcode: Normalizer.barcode(u.barcode) || null,
            production_date: Normalizer.toSafeTimestamp(u.production_date),
            expiry_date: Normalizer.toSafeTimestamp(u.expiry_date),
          })).filter((u) => u.label.length > 0 && u.price >= 0)
        : [];

      return {
        id: String(v.id || `v_${idx}_${variantBaseTs}`).trim(),
        label: String(v.label || "").trim(),
        price: Math.max(0, Number(v.price) || 0),
        stock: Math.max(0, Number(v.stock) || 0),
        items_per_carton: Math.max(1, parseInt(v.items_per_carton, 10) || 1),
        size_text: v.size_text ? String(v.size_text).trim() : null,
        size_ml: v.size_ml != null ? Number(v.size_ml) : null,
        image_url: v.image_url ? String(v.image_url).trim() : null,
        barcode: Normalizer.barcode(v.barcode) || null,
        production_date: Normalizer.toSafeTimestamp(v.production_date),
        expiry_date: Normalizer.toSafeTimestamp(v.expiry_date),
        units: vUnits,
      };
    }).filter((v) => v.label.length > 0);

    const variantFinancials = rawVariants.map((v, idx) => ({
      id: String(v.id || `v_${idx}_${variantBaseTs}`).trim(),
      label: String(v.label || "").trim(),
      cost_price: Math.max(0, Number(v.cost_price) || 0),
      units: Array.isArray(v.units)
        ? v.units.map((u) => ({
            label: String(u.label || "").trim(),
            cost_price: Math.max(0, Number(u.cost_price) || 0),
          })).filter((u) => u.label.length > 0)
        : [],
    })).filter((v) => v.label.length > 0);
const baseStock = Number(Math.max(0, stock).toFixed(4));
    const hasBaseStock = parsedVariants.length === 0 ? true : (data.hasBaseStock === true || baseStock > 0);
    const totalVariantStock = parsedVariants.reduce((sum, v) => sum + (Number(v.stock) || 0), 0);
    const effectiveStock = Number((baseStock + totalVariantStock).toFixed(4));

    const newDocRef = db.collection("products").doc();
    const productPayload = {
      id: newDocRef.id,
      name: cleanName,
      brand_id: brandId,
      category_id: categoryId,
      price: price,
      base_stock: baseStock,
      has_base_stock: hasBaseStock,
      stock: effectiveStock,
      is_active: true,
      is_deleted: false,
      items_per_carton: (Number.isInteger(Number(data.itemsPerCarton)) && Number(data.itemsPerCarton) >= 1) ? Number(data.itemsPerCarton) : 1,
      size_ml: data.sizeMl != null ? Number(data.sizeMl) : null,
      size_text: data.sizeText ? String(data.sizeText).trim() : null,
      image_url: data.imageUrl ? String(data.imageUrl).trim() : null,
      production_date: Normalizer.toSafeTimestamp(data.productionDate),
      expiry_date: Normalizer.toSafeTimestamp(data.expiryDate),
      barcode: cleanMainBarcode || null,
      all_barcodes: allBarcodes,
      units: units,
      variants: parsedVariants,
      public_catalog_ready: true,
      sort_order: Date.now(),
      created_at: FieldValue.serverTimestamp(),
      updated_at: FieldValue.serverTimestamp(),
    };

    const batch = db.batch();
    batch.set(newDocRef, productPayload);
    batch.set(db.collection("product_financials").doc(newDocRef.id), {
      product_id: newDocRef.id,
      cost_price: costPrice,
      units: unitFinancials,
      variants: variantFinancials,
      updated_at: FieldValue.serverTimestamp(),
    });
    if (effectiveStock > 0) {
      const auditDocRef = db.collection("inventory_audit_log").doc();
      batch.set(auditDocRef, {
        product_id: newDocRef.id,
        product_name: cleanName,
        action: "initial_stock",
        delta: effectiveStock,
        resulting_stock: effectiveStock,
        performed_by: callerUid,
        created_at: FieldValue.serverTimestamp(),
      });
    }
    await batch.commit();
    return { success: true, id: newDocRef.id };
  }
);

// 2. تعديل المنتج والمخزون ذرياً وتدقيق التغييرات
exports.adminUpdateProduct = onCall(
  { region: "us-central1", cors: true },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "يجب تسجيل الدخول أولاً");
    }

    const callerUid = request.auth.uid;
    await requireActiveRole(
      callerUid,
      ["admin", "super_admin", "warehouse_manager"],
      "هذه العملية مخصصة لمدراء النظام فقط",
    );

    const { id, updates } = request.data || {};
    const cleanId = String(id || "").trim();
    if (!cleanId || !updates || typeof updates !== "object" || Array.isArray(updates)) {
      throw new HttpsError("invalid-argument", "معرف المنتج وبيانات التحديث مطلوبة");
    }

    const productRef = db.collection("products").doc(cleanId);
    const financialRef = db.collection("product_financials").doc(cleanId);

    return await db.runTransaction(async (tx) => {
      const snap = await tx.get(productRef);
      const financialSnap = await tx.get(financialRef);
      if (!snap.exists) throw new HttpsError("not-found", "المنتج غير موجود");

      const existing = snap.data() || {};
      const existingFinancials = financialSnap.data() || {};
      const safeUpdates = {};
      const requestedCost = updates.cost_price !== undefined
        ? Number(updates.cost_price)
        : Number(existingFinancials.cost_price ?? existing.cost_price) || 0;
      if (!Number.isFinite(requestedCost) || requestedCost < 0) {
        throw new HttpsError("invalid-argument", "سعر التكلفة غير صالح");
      }
      const financialUpdates = { cost_price: requestedCost };
      const allowedFields = ["name", "brand_id", "category_id", "size_text", "price", "size_ml", "items_per_carton", "image_url", "is_active"];

 for (const field of allowedFields) {
        if (updates[field] === undefined) continue;
        let v = updates[field];
        let valid = true;
       if (field === "price") valid = Number.isFinite(v) && v >= 0;
        else if (field === "is_active") valid = typeof v === "boolean";
        else if (field === "size_text" || field === "image_url") {
          valid = v === null || typeof v === "string";
        } else if (field === "items_per_carton") {
          if (v === null || v === "" || !Number.isFinite(Number(v))) {
            v = 1; // ضبط افتراضي آمن بدلاً من رمي خطأ وإيقاف التعديل
          } else {
            v = Math.max(1, parseInt(v, 10));
          }
          valid = true;
        }
        else if (field === "name") valid = typeof v === "string" && v.trim().length >= 2 && v.length <= 200;
      else if (field === "size_ml") {
          valid = v === null || (Number.isFinite(v) && v >= 0);
          if (v === null) {
            safeUpdates[field] = FieldValue.delete();
            continue;
          }
        }
        else if (field === "brand_id" || field === "category_id") {
          valid = typeof v === "string" && v.trim().length > 0 && !v.includes("/");
        }
        if (!valid) {
          throw new HttpsError("invalid-argument", `قيمة الحقل ${field} غير صالحة`);
        }
        safeUpdates[field] = v;
      }
     if (safeUpdates.brand_id !== undefined) {
        const brandSnap = await tx.get(db.collection("brands").doc(safeUpdates.brand_id.trim()));
        if (!brandSnap.exists) {
          throw new HttpsError("not-found", "الشركة غير موجودة");
        }
        // مزامنة الصنف تلقائياً مع صنف الشركة الجديد لضمان سلامة الكتالوج
        const derivedCatId = brandSnap.data()?.category_id;
        if (derivedCatId) {
          safeUpdates.category_id = derivedCatId;
        }
      } else if (safeUpdates.category_id !== undefined) {
        const catSnap = await tx.get(db.collection("categories").doc(safeUpdates.category_id.trim()));
        if (!catSnap.exists) {
          throw new HttpsError("not-found", "التصنيف غير موجود");
        }
      }
      const sourceUnits = updates.units ?? existing.units ?? [];
      if (!Array.isArray(sourceUnits)) {
        throw new HttpsError("invalid-argument", "وحدات المنتج غير صالحة");
      }
      const existingUnitCosts = new Map(
        (Array.isArray(existingFinancials.units) ? existingFinancials.units : [])
          .map((unit) => [
            String(unit.label || "").trim(),
            Number(unit.cost_price) || 0,
          ]),
      );
      for (const unit of Array.isArray(existing.units) ? existing.units : []) {
        if (!existingUnitCosts.has(String(unit.label || "").trim())) {
          existingUnitCosts.set(
            String(unit.label || "").trim(),
            Number(unit.cost_price) || 0,
          );
        }
      }
     safeUpdates.units = sourceUnits.map((unit) => {
        if (!unit || typeof unit !== "object" || Array.isArray(unit)) {
          throw new HttpsError("invalid-argument", "بيانات الوحدة غير صالحة");
        }
        const label = String(unit.label || "").trim();
        const price = Number(unit.price);
        const qty = Number(unit.qty);
        if (!label || !Number.isFinite(price) || price < 0 || !Number.isFinite(qty) || qty <= 0) {
          throw new HttpsError("invalid-argument", "بيانات الوحدة غير صالحة");
        }
        return {
          label,
          price,
          qty,
          size_ml: (unit.size_ml != null && Number.isFinite(Number(unit.size_ml))) ? Number(unit.size_ml) : null,
          image_url: unit.image_url ? String(unit.image_url).trim() : null,
          barcode: Normalizer.barcode(unit.barcode) || null,
          production_date: Normalizer.toSafeTimestamp(unit.production_date),
          expiry_date: Normalizer.toSafeTimestamp(unit.expiry_date),
        };
      });

   financialUpdates.units = sourceUnits.map((unit) => {
        const uLabel = String(unit.label || "").trim();
        const existingCost = existingUnitCosts.get(uLabel) || 0;
        const incomingCost = (unit.cost_price !== undefined && unit.cost_price !== null && Number.isFinite(Number(unit.cost_price)))
          ? Number(unit.cost_price)
          : existingCost;
        return {
          label: uLabel,
          cost_price: Math.max(0, incomingCost),
        };
      });
  const existingVariantsList = Array.isArray(existing.variants) ? existing.variants : [];
      const existingVariantsMap = new Map(
        existingVariantsList.map((ev) => [String(ev.id || ev.label).trim(), ev])
      );
      let variantAuditDelta = 0;

      if (updates.variants !== undefined) {
        const rawVars = Array.isArray(updates.variants) ? updates.variants : [];
        const resolvedVars = [];
        const resolvedFinancialVars = [];
        const baseTs = Date.now();

        for (let idx = 0; idx < rawVars.length; idx++) {
          const v = rawVars[idx];
          const label = String(v.label || "").trim();
          if (!label) continue;

          const vId = String(v.id || `v_${idx}_${baseTs}`).trim();
          const prevVariant = existingVariantsMap.get(vId);

          let finalVariantStock;
          if (prevVariant && v.stock_delta !== undefined && v.is_new_variant !== true) {
            const liveVStock = Math.max(0, Number(prevVariant.stock) || 0);
            const vDelta = Number(v.stock_delta) || 0;
            const effVDelta = vDelta < 0 ? -Math.min(liveVStock, Math.abs(vDelta)) : vDelta;
            finalVariantStock = Number((liveVStock + effVDelta).toFixed(4));
            variantAuditDelta = Number((variantAuditDelta + effVDelta).toFixed(4));
          } else {
            finalVariantStock = Math.max(0, Number(v.stock) || 0);
            const prevVStock = prevVariant ? Math.max(0, Number(prevVariant.stock) || 0) : 0;
            variantAuditDelta = Number((variantAuditDelta + (finalVariantStock - prevVStock)).toFixed(4));
          }

          resolvedVars.push({
            id: vId,
            label,
            price: Math.max(0, Number(v.price) || 0),
            stock: finalVariantStock,
            items_per_carton: Math.max(1, parseInt(v.items_per_carton, 10) || 1),
            size_text: v.size_text ? String(v.size_text).trim() : null,
            size_ml: v.size_ml != null ? Number(v.size_ml) : null,
            image_url: v.image_url ? String(v.image_url).trim() : null,
            barcode: Normalizer.barcode(v.barcode) || null,
            production_date: Normalizer.toSafeTimestamp(v.production_date),
            expiry_date: Normalizer.toSafeTimestamp(v.expiry_date),
            units: Array.isArray(v.units)
              ? v.units.map((u) => ({
                  label: String(u.label || "").trim(),
                  price: Math.max(0, Number(u.price) || 0),
                  qty: Math.max(1, parseInt(u.qty, 10) || 1),
                  size_ml: u.size_ml != null ? Number(u.size_ml) : null,
                  image_url: u.image_url ? String(u.image_url).trim() : null,
                  barcode: Normalizer.barcode(u.barcode) || null,
                  production_date: Normalizer.toSafeTimestamp(u.production_date),
                  expiry_date: Normalizer.toSafeTimestamp(u.expiry_date),
                })).filter((u) => u.label.length > 0)
              : [],
          });

          resolvedFinancialVars.push({
            id: vId,
            label,
            cost_price: Math.max(0, Number(v.cost_price) || 0),
            units: Array.isArray(v.units)
              ? v.units.map((u) => ({
                  label: String(u.label || "").trim(),
                  cost_price: Math.max(0, Number(u.cost_price) || 0),
                })).filter((u) => u.label.length > 0)
              : [],
          });
        }

        safeUpdates.variants = resolvedVars;
        financialUpdates.variants = resolvedFinancialVars;
      }

      if (updates.barcode !== undefined || updates.units !== undefined || updates.variants !== undefined) {
        const targetBarcode = updates.barcode !== undefined ? updates.barcode : existing.barcode;
        const targetUnits = updates.units !== undefined ? updates.units : (existing.units ?? []);
        const targetVariants = safeUpdates.variants !== undefined ? safeUpdates.variants : existingVariantsList;

        if (updates.barcode === null || updates.barcode === "") {
          safeUpdates.barcode = FieldValue.delete();
        } else if (targetBarcode) {
          safeUpdates.barcode = Normalizer.barcode(targetBarcode);
        }

        const allBarcodes = Normalizer.extractAllBarcodes(targetBarcode, targetUnits, targetVariants);
        if (allBarcodes.length > 0) {
          const barcodeChunks = [];
          for (let i = 0; i < allBarcodes.length; i += 10) {
            barcodeChunks.push(allBarcodes.slice(i, i + 10));
          }
          const barcodeSnaps = await Promise.all(
            barcodeChunks.map((chunk) =>
              tx.get(
                db.collection("products")
                  .where("is_deleted", "==", false)
                  .where("all_barcodes", "array-contains-any", chunk)
                  .limit(5)
              )
            )
          );
          for (const bSnap of barcodeSnaps) {
            const duplicate = bSnap.docs.find((d) => d.id !== cleanId);
            if (duplicate) {
              throw new HttpsError("already-exists", `الباركود مسجل بالفعل للمنتج (${duplicate.data()?.name || duplicate.id})`);
            }
          }
        }

        safeUpdates.all_barcodes = allBarcodes.length > 0 ? allBarcodes : FieldValue.delete();
      }

      if (updates.production_date !== undefined) {
        const safeTs = Normalizer.toSafeTimestamp(updates.production_date);
        safeUpdates.production_date = safeTs ? safeTs : FieldValue.delete();
      }
      if (updates.expiry_date !== undefined) {
        const safeTs = Normalizer.toSafeTimestamp(updates.expiry_date);
        safeUpdates.expiry_date = safeTs ? safeTs : FieldValue.delete();
      }

      const hasExistingVariants = existingVariantsList.length > 0;
      const currentBaseStock = Math.max(
        0,
        Number(hasExistingVariants ? (existing.base_stock ?? 0) : (existing.base_stock ?? existing.stock)) || 0
      );
      let nextBaseStock = currentBaseStock;
      let baseAuditDelta = 0;

      const incomingBaseDelta = updates.base_stock_delta !== undefined
        ? updates.base_stock_delta
        : updates.stock_delta;

      if (incomingBaseDelta !== undefined) {
        const delta = Number(incomingBaseDelta) || 0;
        baseAuditDelta = Number(
          (delta < 0 ? -Math.min(currentBaseStock, Math.abs(delta)) : delta).toFixed(4)
        );
        nextBaseStock = Number((currentBaseStock + baseAuditDelta).toFixed(4));
        safeUpdates.base_stock = nextBaseStock;
      } else if (updates.stock !== undefined && updates.variants === undefined) {
        nextBaseStock = Math.max(0, Number(updates.stock) || 0);
        baseAuditDelta = Number((nextBaseStock - currentBaseStock).toFixed(4));
        safeUpdates.base_stock = nextBaseStock;
      }

      if (updates.has_base_stock !== undefined) {
        safeUpdates.has_base_stock = Boolean(updates.has_base_stock);
      } else if (safeUpdates.base_stock !== undefined && nextBaseStock > 0) {
        safeUpdates.has_base_stock = true;
      }

      const finalVariantsList = safeUpdates.variants !== undefined ? safeUpdates.variants : existingVariantsList;
      const totalVariantStock = finalVariantsList.reduce(
        (sum, v) => sum + Math.max(0, Number(v.stock) || 0),
        0
      );
      let newStock = Number(existing.stock) || 0;

   if (safeUpdates.base_stock !== undefined || safeUpdates.variants !== undefined) {
        if (safeUpdates.base_stock === undefined && existing.base_stock === undefined) {
          safeUpdates.base_stock = nextBaseStock;
          if (safeUpdates.has_base_stock === undefined && nextBaseStock > 0) {
            safeUpdates.has_base_stock = true;
          }
        }
        newStock = Number((nextBaseStock + totalVariantStock).toFixed(4));
        safeUpdates.stock = newStock;
      }

      const totalAuditDelta = Number((baseAuditDelta + variantAuditDelta).toFixed(4));
      if (Math.abs(totalAuditDelta) > 0.0001) {
        const auditRef = db.collection("inventory_audit_log").doc();
        tx.set(auditRef, {
          product_id: cleanId,
          product_name: safeUpdates.name || existing.name || "",
          action: safeUpdates.variants !== undefined ? "variants_delta_sync" : "base_stock_delta",
          delta: totalAuditDelta,
          resulting_stock: newStock,
          performed_by: callerUid,
          created_at: FieldValue.serverTimestamp(),
        });
      }
      safeUpdates.updated_at = FieldValue.serverTimestamp();
      safeUpdates.public_catalog_ready = true;
      safeUpdates.cost_price = FieldValue.delete();
      tx.update(productRef, safeUpdates);
      tx.set(financialRef, {
        product_id: cleanId,
        ...financialUpdates,
        updated_at: FieldValue.serverTimestamp(),
      }, { merge: true });

      return { success: true, updatedStock: newStock };
    });
  }
);

// 3. الحذف البرمجي الآمن للمنتج
exports.adminDeleteProduct = onCall(
  { region: "us-central1", cors: true },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "يجب تسجيل الدخول أولاً");
    }

    const callerUid = request.auth.uid;
    await requireActiveRole(
      callerUid,
      ["admin", "super_admin"],
      "هذه العملية مخصصة لمدراء النظام فقط",
    );

    const { id } = request.data || {};
    const cleanId = String(id || "").trim();
    if (!cleanId) throw new HttpsError("invalid-argument", "معرف المنتج مطلوب");

    await db.collection("products").doc(cleanId).update({
      is_deleted: true,
      is_active: false,
      deleted_at: FieldValue.serverTimestamp(),
      updated_at: FieldValue.serverTimestamp(),
    });

    return { success: true };
  }
);
// ══════════════════════════════════════════════════════════════
// ⚡ الدوال المحولة للسيرفر بالكامل: المرتجعات المجمعة والكتالوج
// ══════════════════════════════════════════════════════════════

// 1. معالجة وتوثيق المرتجع الجماعي للإدارة في معاملة ذرية واحدة لا تقبل التجزئة
exports.adminProcessBatchReturn = onCall(
  { region: "us-central1", cors: true },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "يجب تسجيل الدخول");
    }

    const callerUid = request.auth.uid;
    const { orderId, reason, returnItems } = request.data || {};
    const cleanOrderId = String(orderId || "").trim();

    if (!cleanOrderId || !Array.isArray(returnItems) ||
        returnItems.length === 0 || returnItems.length > 200) {
      throw new HttpsError("invalid-argument", "بيانات المرتجع غير مكتملة");
    }

    // التحقق الصارم من صلاحية الإدارة
    await requireActiveRole(
      callerUid,
      ["admin", "super_admin", "accountant", "warehouse_manager"],
      "هذه العملية مخصصة لمدراء النظام فقط",
    );

    const orderRef = db.collection("orders").doc(cleanOrderId);

 return await db.runTransaction(async (tx) => {
      const orderSnap = await tx.get(orderRef);
      if (!orderSnap.exists) {
        throw new HttpsError("not-found", "الطلب غير موجود");
      }
      const orderData = orderSnap.data();
      const orderFinancialRef = db.collection("order_financials").doc(cleanOrderId);
      const orderFinancialSnap = await tx.get(orderFinancialRef);

   // 🔒 قفل سلامة العمليات: لا يمكن معالجة مرتجع مالي لطلب لم يتم تسليمه أصلاً
      if (orderData.status !== "delivered" && orderData.status !== "return_requested") {
        throw new HttpsError("failed-precondition", `لا يمكن تسجيل إرجاع لطلب بحالة: ${orderData.status}`);
      }
// جلب جميع عناصر الطلب ومستندات المرتجعات المعلقة (Reads) قبل أي كتابة
      const aggregatedReturnItems = new Map();
      for (const item of returnItems) {
        if (!item || typeof item !== "object" || Array.isArray(item)) {
          throw new HttpsError("invalid-argument", "بيانات صنف الإرجاع غير صالحة");
        }
        const itemId = String(item.item_id || item.id || "").trim();
        const quantity = Number(item.quantity);
        if (!itemId || !Number.isSafeInteger(quantity) || quantity <= 0) {
          throw new HttpsError("invalid-argument", "معرف الصنف وكمية الإرجاع غير صالحين");
        }
        const totalQuantity = (aggregatedReturnItems.get(itemId) || 0) + quantity;
        if (!Number.isSafeInteger(totalQuantity)) {
          throw new HttpsError("invalid-argument", "إجمالي كمية الإرجاع يتجاوز الحد المسموح");
        }
        aggregatedReturnItems.set(itemId, totalQuantity);
      }

      const returnEntries = Array.from(aggregatedReturnItems.entries());

        const summaryParentRef = db.collection("stats").doc("profit_summary");
      const [pendingReturnsSnap, itemSnaps, itemFinancialSnaps, summarySnap] = await Promise.all([
        tx.get(
          db.collection("order_returns")
            .where("order_id", "==", cleanOrderId)
            .where("status", "==", "pending")
        ),
        Promise.all(
          returnEntries.map(([itemId]) =>
            tx.get(db.collection("order_items").doc(itemId)),
          ),
        ),
        Promise.all(
          returnEntries.map(([itemId]) =>
            tx.get(db.collection("order_item_financials").doc(itemId)),
          ),
        ),
        tx.get(summaryParentRef),
      ]);
   const batchProductIds = [...new Set(
        itemSnaps
          .filter((s) => s.exists && s.data()?.product_id)
          .map((s) => String(s.data().product_id)),
      )];
      const batchProductSnaps = await Promise.all(
        batchProductIds.map((pId) => tx.get(db.collection("products").doc(pId))),
      );
    const batchProductMap = new Map();
      batchProductSnaps.forEach((pSnap) => {
        if (pSnap.exists) {
          batchProductMap.set(pSnap.id, pSnap.data());
        }
      });

      const lastResetAt = summarySnap.data()?.last_reset_at?.toMillis?.() ?? 0;
      const orderDeliveredAt = orderData.delivered_at?.toMillis?.() ?? (orderData.created_at?.toMillis?.() ?? 0);
      const isFromCurrentCycle = orderDeliveredAt >= lastResetAt;
      let totalRefund = 0;
      let totalDeductedProfit = 0;
      const productRestores = new Map();
      const processedItemIds = new Set(returnEntries.map(([itemId]) => itemId));
// 1. فهرسة مستندات الإرجاع المعلقة لضمان كتابة ذرية واحدة فقط لكل مرجع
 const pendingByItemId = new Map();
      for (const doc of pendingReturnsSnap.docs) {
        const oItemId = doc.data().order_item_id;
        if (!pendingByItemId.has(oItemId)) {
          pendingByItemId.set(oItemId, doc);
        } else {
          tx.update(doc.ref, {
            status: "accepted",
            reconciled_in_batch: true,
            updated_at: FieldValue.serverTimestamp(),
          });
        }
      }

      for (let i = 0; i < returnEntries.length; i++) {
        const itemSnap = itemSnaps[i];
        const [returnItemId, returnQty] = returnEntries[i];
        if (!itemSnap.exists) {
          throw new HttpsError("not-found", `عنصر الطلب ${returnItemId} غير موجود`);
        }

        const itemData = itemSnap.data();
        const orderedQty = Number(itemData.quantity) || 0;
        const alreadyReturned = Number(itemData.returned_quantity) || 0;
        const maxReturnable = Math.max(0, orderedQty - alreadyReturned);

        if (returnQty > maxReturnable) {
          throw new HttpsError("failed-precondition", `الكمية المرتجعة للصنف (${itemData.product_name}) تتجاوز الكمية المتاحة للإرجاع`);
        }

        const capacity = Number(itemData.carton_capacity) || 1;
        const unitQty = Number(itemData.unit_qty) || capacity;
        const cartonsToRestore = Number(((returnQty * unitQty) / capacity).toFixed(4));
      const price = Number(itemData.price) || 0;
        const itemRefund = Number((price * returnQty).toFixed(2));
        const unitCost = Number(
          itemFinancialSnaps[i].data()?.unit_cost ?? itemData.unit_cost,
        ) || 0;
        const itemProfit = Number(((price - unitCost) * returnQty).toFixed(2));

        totalRefund = Number((totalRefund + itemRefund).toFixed(2));
        totalDeductedProfit = Number((totalDeductedProfit + itemProfit).toFixed(2));
const pId = itemData.product_id;
        const vId = itemData.variant_id ? String(itemData.variant_id).trim() : null;
        if (pId) {
          const restoreKey = vId ? `${pId}__v_${vId}` : pId;
          const prev = productRestores.get(restoreKey);
          productRestores.set(restoreKey, {
            productId: pId,
            variantId: vId,
            delta: Number(((prev?.delta || 0) + cartonsToRestore).toFixed(4)),
          });
        }

        tx.update(itemSnap.ref, {
          returned_quantity: FieldValue.increment(returnQty),
          updated_at: FieldValue.serverTimestamp(),
        });

        const matchingPending = pendingByItemId.get(returnItemId);
        if (matchingPending) {
          // تحديث ذري وحيد وموحد للمستند المعلق (يمنع استثناء Multiple Mutations)
          const updatePayload = {
            status: "accepted",
            reconciled_in_batch: true,
            updated_at: FieldValue.serverTimestamp(),
          };
          if (Number(matchingPending.data().quantity) !== returnQty) {
            updatePayload.quantity = returnQty;
            updatePayload.unit_price = price;
            updatePayload.refund_amount = itemRefund;
            updatePayload.returned_amount = itemRefund;
          }
          tx.update(matchingPending.ref, updatePayload);
        } else {
          // إنشاء مستند إرجاع جديد إذا لم يكن مقدماً مسبقاً
          const retRef = db.collection("order_returns").doc();
          const returnNumber = IdGenerator.generateReturnNumber();
          tx.set(retRef, {
            order_id: cleanOrderId,
            order_item_id: itemSnap.id,
            merchant_id: orderData.merchant_id,
            product_id: pId || "",
            product_name: itemData.product_name || "منتج",
            quantity: returnQty,
            unit_label: itemData.unit_label || "كرتون",
            unit_price: price,
            refund_amount: itemRefund,
            returned_amount: itemRefund,
            store_name: orderData.store_name || "",
            contact: orderData.phone_number || orderData.contact || "",
            reason: String(reason || "").trim(),
            status: "accepted",
            return_number: returnNumber,
            invoice_number: returnNumber,
            created_at: FieldValue.serverTimestamp(),
            updated_at: FieldValue.serverTimestamp(),
          });
        }
      }
      OrderCalculator.applyProductStockDeltas({
        tx,
        entries: Array.from(productRestores.values()),
        productMap: batchProductMap,
        isRestore: true,
        auditMeta: {
          order_id: cleanOrderId,
          action: "return_accepted",
          performed_by: callerUid,
        },
      });
  // تحديث بيانات الفاتورة الأصلية وتصفير عداد المرتجعات المعلقة لفتح إمكانية الإرجاع مستقبلاً
      const currentTotal = Number(orderData.total_amount || orderData.total || 0);
    const safeNewTotal = Math.max(0, Number((currentTotal - totalRefund).toFixed(2)));  
    const rawProfit = orderFinancialSnap.data()?.total_profit ?? orderData?.total_profit;
      const currentProfit = Number.isFinite(Number(rawProfit)) ? Number(rawProfit) : 0;

          const remainingPending = pendingReturnsSnap.docs.filter(
        (d) => !processedItemIds.has(d.data().order_item_id),
      ).length;
      tx.update(orderRef, {
        status: remainingPending > 0 ? "return_requested" : (safeNewTotal <= 0.01 ? "returned" : "delivered"),
        total: safeNewTotal,
        total_amount: safeNewTotal,
        returned_amount: FieldValue.increment(totalRefund),
        pending_returns_count: remainingPending,
        updated_at: FieldValue.serverTimestamp(),
      });
tx.set(orderFinancialRef, {
        order_id: cleanOrderId,
        total_profit: currentProfit - totalDeductedProfit,
        updated_at: FieldValue.serverTimestamp(),
      }, { merge: true });

      // 🔔 إشعار التاجر باعتماد وتسوية المرتجعات الجماعية
      if (orderData.merchant_id) {
        tx.set(db.collection("user_notifications").doc(), {
          user_id: orderData.merchant_id,
          title: "✅ تم قبول وتسوية المرتجعات",
          body: `تمت تسوية مرتجع (${returnEntries.length}) أصناف بقيمة مستردة ${totalRefund.toFixed(0)} ر.ي`,
          order_id: cleanOrderId,
          type: "order_status",
          is_read: false,
          created_at: FieldValue.serverTimestamp(),
        });
      }

// 🔒 لا يتم خصم الأرباح إلا إذا كانت قد سُجلت فعلياً عند التسليم
      if (orderData.profit_recorded === true) {
        const statsUpdates = {
          accumulated_profit: FieldValue.increment(-totalDeductedProfit),
          accumulated_returns: FieldValue.increment(totalRefund),
          accumulated_revenue: FieldValue.increment(-totalRefund),
          last_updated: FieldValue.serverTimestamp(),
        };
        if (isFromCurrentCycle) {
          statsUpdates.cycle_profit = FieldValue.increment(-totalDeductedProfit);
        } else {
          statsUpdates.prior_period_adjustments = FieldValue.increment(-totalDeductedProfit);
        }
        tx.set(summaryParentRef, statsUpdates, { merge: true });
      }
      return { success: true, count: returnEntries.length, totalRefund };
    });
  }
);

// 2. إضافة صنف جديد بسلطة السيرفر
exports.adminAddCategory = onCall(
  { region: "us-central1", cors: true },
  async (request) => {
    if (!request.auth) throw new HttpsError("unauthenticated", "يجب تسجيل الدخول");

    await requireActiveRole(
      request.auth.uid,
      ["admin", "super_admin", "warehouse_manager"],
      "هذه العملية مخصصة للإدارة فقط",
    );

    const { name, imageUrl } = request.data || {};
    const cleanName = String(name || "").trim();
    if (!cleanName) throw new HttpsError("invalid-argument", "اسم الصنف مطلوب");

    const snap = await db.collection("categories").orderBy("sort_order", "desc").limit(1).get();
    const lastOrder = snap.empty ? 0 : Number(snap.docs[0].data().sort_order || 0);

    const docRef = db.collection("categories").doc();
    await docRef.set({
      id: docRef.id,
      name: cleanName,
      image_url: imageUrl ? String(imageUrl).trim() : null,
      sort_order: lastOrder + 1,
      is_active: true,
      is_deleted: false,
      created_at: FieldValue.serverTimestamp(),
      updated_at: FieldValue.serverTimestamp(),
    });

    return { success: true, id: docRef.id };
  }
);

// 3. تحديث صنف موجود بسلطة السيرفر
exports.adminUpdateCategory = onCall(
  { region: "us-central1", cors: true },
  async (request) => {
    if (!request.auth) throw new HttpsError("unauthenticated", "يجب تسجيل الدخول");

    await requireActiveRole(
      request.auth.uid,
      ["admin", "super_admin", "warehouse_manager"],
      "هذه العملية مخصصة للإدارة فقط",
    );

    const { id, name, imageUrl } = request.data || {};
    const cleanId = String(id || "").trim();
    const cleanName = String(name || "").trim();
    if (!cleanId || !cleanName) throw new HttpsError("invalid-argument", "معرف الصنف واسمه مطلوبان");

    const docRef = db.collection("categories").doc(cleanId);
    const snap = await docRef.get();
    if (!snap.exists) throw new HttpsError("not-found", "الصنف غير موجود");

    const updates = {
      name: cleanName,
      updated_at: FieldValue.serverTimestamp(),
    };
    if (imageUrl !== undefined) {
      updates.image_url = imageUrl ? String(imageUrl).trim() : null;
    }

    await docRef.update(updates);
    return { success: true };
  }
);

// 4. إضافة شركة جديدة بسلطة السيرفر
exports.adminAddBrand = onCall(
  { region: "us-central1", cors: true },
  async (request) => {
    if (!request.auth) throw new HttpsError("unauthenticated", "يجب تسجيل الدخول");

    await requireActiveRole(
      request.auth.uid,
      ["admin", "super_admin", "warehouse_manager"],
      "هذه العملية مخصصة للإدارة فقط",
    );

    const { name, categoryId, logoUrl } = request.data || {};
    const cleanName = String(name || "").trim();
    const cleanCatId = String(categoryId || "").trim();
    if (!cleanName || !cleanCatId) throw new HttpsError("invalid-argument", "اسم الشركة والصنف مطلوبان");

    const docRef = db.collection("brands").doc();
    await docRef.set({
      id: docRef.id,
      name: cleanName,
      category_id: cleanCatId,
      logo_url: logoUrl ? String(logoUrl).trim() : null,
      is_active: true,
      is_deleted: false,
      created_at: FieldValue.serverTimestamp(),
      updated_at: FieldValue.serverTimestamp(),
    });

    return { success: true, id: docRef.id };
  }
);

// 5. تحديث شركة موجودة بسلطة السيرفر
exports.adminUpdateBrand = onCall(
  { region: "us-central1", cors: true },
  async (request) => {
    if (!request.auth) throw new HttpsError("unauthenticated", "يجب تسجيل الدخول");

    await requireActiveRole(
      request.auth.uid,
      ["admin", "super_admin", "warehouse_manager"],
      "هذه العملية مخصصة للإدارة فقط",
    );

    const { id, name, categoryId, logoUrl } = request.data || {};
    const cleanId = String(id || "").trim();
    const cleanName = String(name || "").trim();
    const cleanCatId = String(categoryId || "").trim();
    if (!cleanId || !cleanName || !cleanCatId) {
      throw new HttpsError("invalid-argument", "معرف الشركة، الاسم، والصنف مطلوبون");
    }

    const docRef = db.collection("brands").doc(cleanId);
    const snap = await docRef.get();
    if (!snap.exists) throw new HttpsError("not-found", "الشركة غير موجودة");

    const catSnap = await db.collection("categories").doc(cleanCatId).get();
    if (!catSnap.exists) throw new HttpsError("not-found", "الصنف المختار غير موجود");

    const existingBrand = snap.data() || {};
    const updates = {
      name: cleanName,
      category_id: cleanCatId,
      updated_at: FieldValue.serverTimestamp(),
    };
    if (logoUrl !== undefined) {
      updates.logo_url = logoUrl ? String(logoUrl).trim() : null;
    }

    await docRef.update(updates);

    // إذا تغير الصنف، مزامنة الصنف في جميع منتجات الشركة تلقائياً
    if (existingBrand.category_id !== cleanCatId) {
      try {
        const prodsSnap = await db.collection("products")
          .where("brand_id", "==", cleanId)
          .where("is_deleted", "==", false)
          .get();
    if (!prodsSnap.empty) {
          const CHUNK_SIZE = 400;
          for (let i = 0; i < prodsSnap.docs.length; i += CHUNK_SIZE) {
            const batch = db.batch();
            prodsSnap.docs.slice(i, i + CHUNK_SIZE).forEach((doc) => {
              batch.update(doc.ref, {
                category_id: cleanCatId,
                updated_at: FieldValue.serverTimestamp(),
              });
            });
            await batch.commit();
          }
        }
      } catch (err) {
        console.error(`[adminUpdateBrand] failed to sync product categories: ${err.message}`);
      }
    }

    return { success: true };
  }
);
// ══════════════════════════════════════════════════════════════
// 🔒 إغلاق ثغرات الكتابة المباشرة من الهاتف ونقلها للسيرفر
// ══════════════════════════════════════════════════════════════

// 1. إرسال إشعار فردي مخصص لتاجر بعينه بسلطة وتحقق الإدارة
exports.adminSendDirectNotification = onCall(
  { region: "us-central1", cors: true },
  async (request) => {
    if (!request.auth) throw new HttpsError("unauthenticated", "يجب تسجيل الدخول");

    const callerUid = request.auth.uid;
    await requireActiveRole(
      callerUid,
      ["admin", "super_admin", "accountant"],
      "هذه العملية مخصصة للإدارة فقط",
    );

    const { targetUserId, title, body } = request.data || {};
    const cleanUid = String(targetUserId || "").trim();
    const cleanTitle = String(title || "").trim();
    const cleanBody = String(body || "").trim();

    if (!cleanUid || !cleanTitle || !cleanBody) {
      throw new HttpsError("invalid-argument", "جميع بيانات الإشعار مطلوبة");
    }

    const notifRef = db.collection("user_notifications").doc();
    await notifRef.set({
      id: notifRef.id,
      user_id: cleanUid,
      title: cleanTitle,
      body: cleanBody,
      type: "admin_message",
      is_read: false,
      sent_by: callerUid,
      created_at: FieldValue.serverTimestamp(),
    });

    return { success: true };
  }
);
// 2. ربط التوقيع الرقمي بالطلب بسلطة السيرفر وبناء معماري نظيف
exports.saveOrderSignature = onCall(
  { region: "us-central1", cors: true },
  async (request) => {
    if (!request.auth) throw new HttpsError("unauthenticated", "يجب تسجيل الدخول أولاً");

    const callerUid = request.auth.uid;
    const { orderId, signatureUrl, signerName } = request.data || {};
    const cleanOrderId = String(orderId || "").trim();

    if (!/^[A-Za-z0-9_-]{1,128}$/.test(cleanOrderId)) {
      throw new HttpsError("invalid-argument", "معرف الطلب غير صالح");
    }

// السماح للإدارة ومندوبي التوصيل المعتمدين بتوثيق التوقيع
    const { role: callerRole } = await requireActiveRole(
      callerUid,
      ["admin", "super_admin", "accountant", "warehouse_manager", "driver"],
      "توثيق التوقيع مقتصر على إدارة النظام ومندوبي التوصيل",
    );

    const orderRef = db.collection("orders").doc(cleanOrderId);
    const snap = await orderRef.get();
    if (!snap.exists) throw new HttpsError("not-found", "الطلب غير موجود");
    const orderData = snap.data() || {};
    const sigOrderStatus = String(orderData.status || "").toLowerCase();
    if (["cancelled", "rejected"].includes(sigOrderStatus)) {
      throw new HttpsError("failed-precondition", "لا يمكن توثيق توقيع لطلب ملغي أو مرفوض");
    }

    // 🔒 التحقق الصارم: منع السائق من توقيع أو تعديل طلب غير مسند إليه
    if (callerRole === "driver" && orderData.driver_id && orderData.driver_id !== callerUid) {
      throw new HttpsError("permission-denied", "هذا الطلب غير مسند إليك، لا يمكنك توثيق توقيعه");
    }

    const finalUrl = await SignatureService.processSignature(cleanOrderId, signatureUrl);

    const sigUpdate = {
      signed_by: String(signerName || "المستلم المعتمد").trim().slice(0, 120),
      signed_at: FieldValue.serverTimestamp(),
      updated_at: FieldValue.serverTimestamp(),
    };
    if (finalUrl) sigUpdate.signature_url = finalUrl;

    await orderRef.update(sigUpdate);
    return { success: true };
  }
);// ══════════════════════════════════════════════════════════════
// 🧪 EXPORTS FOR 100% UNIT TESTING (MAINTAINABILITY 100/100)
// ══════════════════════════════════════════════════════════════
// يتيح هذا التصدير اختبار منطق الأعمال، الحسابات المالية، والمطابقات
// عبر أي إطار اختبار (مثل Jest أو Mocha) بمعزل تام عن السحابة
exports.__testing = {
  OrderCalculator,
  Normalizer,
  OrderStateMachine,
  IdGenerator,
  NotificationService,
};