-- =====================================================
-- ADIM 1: Veritabanı bağlamını doğru veritabanına ayarla
-- =====================================================
USE OlistDB;
GO

-- =====================================================
-- ADIM 2: 9 tablonun şemasını keşfet (kolon isimleri ve tipleri)
-- =====================================================
SELECT TABLE_NAME, COLUMN_NAME, DATA_TYPE
FROM INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_NAME IN (
    'customers', 'geolocation', 'order_items', 'order_payments',
    'order_reviews', 'orders', 'product_category_name_translation',
    'products', 'sellers'
)
ORDER BY TABLE_NAME, ORDINAL_POSITION;


-- =====================================================
-- ADIM 3: order_items tablosunda composite primary key sorunu
-- Sorun: order_id tek başına PK olamaz çünkü bir siparişte birden 
-- fazla ürün kalemi olabilir (order_id tekrar eder).
-- Çözüm: order_id + order_item_id birlikte benzersizdir.
-- =====================================================
ALTER TABLE order_items
ADD CONSTRAINT PK_order_items PRIMARY KEY (order_id, order_item_id);


-- =====================================================
-- ADIM 4: Her siparişin toplam kaç ürün kalemi içerdiği ve 
-- toplam tutarı (price + freight_value) nedir?
-- =====================================================
SELECT order_id,
       COUNT(order_item_id) AS toplam_kalem_sayisi,
       SUM(price + freight_value) AS toplam_tutar,
       RANK() OVER (ORDER BY SUM(price + freight_value) DESC) AS tutar_sirasi
FROM order_items
GROUP BY order_id
ORDER BY toplam_tutar DESC;


-- =====================================================
-- ADIM 5: Her siparişin kaç kalem içerdiği nedir, ve siparişler 
-- kalem sayısına göre nasıl sıralanır? RANK() ve DENSE_RANK() 
-- aynı anda kullanılarak iki sıralama yöntemi karşılaştırıldı.
-- Not: Eşit kalem sayısına sahip siparişlerde RANK() bir sonraki 
-- sırayı atlar (2,2,2,5), DENSE_RANK() atlamadan devam eder (2,2,2,3).
-- =====================================================
SELECT order_id,
       COUNT(order_item_id) AS toplam_kalem_sayisi,
       RANK() OVER (ORDER BY COUNT(order_item_id) DESC) AS rank_sirasi,
       DENSE_RANK() OVER (ORDER BY COUNT(order_item_id) DESC) AS dense_rank_sirasi
FROM order_items
GROUP BY order_id
ORDER BY toplam_kalem_sayisi DESC;


-- =====================================================
-- ADIM 6: Satıcı bazında toplam satılan ürün kalemi sayısını ve 
-- toplam ciroyu hesaplar, en yüksek ciroya göre sıralar.
-- LEFT JOIN kullanıldı çünkü hiç satışı olmayan satıcıları da 
-- görmek istiyoruz.
-- =====================================================
SELECT s.seller_id,
       s.seller_state,
       COUNT(oi.order_item_id) AS toplam_kalem_sayisi,
       SUM(oi.price + oi.freight_value) AS toplam_ciro
FROM sellers s
LEFT JOIN order_items oi ON s.seller_id = oi.seller_id
GROUP BY s.seller_id, s.seller_state
ORDER BY toplam_ciro DESC;


-- =====================================================
-- ADIM 7 (FİNAL SORGU): Satıcı bazında toplam kalem sayısı, ciro, 
-- ortalama teslimat gecikmesi, ortalama review score ve ortalama 
-- taksit sayısını hesaplar; review ve payment CTE'lerle önce 
-- sipariş bazında tekilleştirilerek JOIN çarpanı hatası önlenir.
-- Ardından 4 metrik min-max normalizasyon ile 0-1 arasına çekilir 
-- ve belirlenen ağırlıklarla (taksit %40, review %30, gecikme %20, 
-- ciro %10) birleştirilip bir risk skoru üretilir. 
-- Yüksek skor = yüksek risk.
-- Küçük örneklem sorununu önlemek için sadece en az 5 kalem 
-- satmış satıcılara uygulanır.
-- =====================================================
WITH cte_reviews AS (
    SELECT order_id, AVG(CAST(review_score AS FLOAT)) AS ort_review_score
    FROM order_reviews
    GROUP BY order_id
),
cte_payments AS (
    SELECT order_id, AVG(CAST(payment_installments AS FLOAT)) AS ort_taksit_sayisi
    FROM order_payments
    GROUP BY order_id
),
satici_metrikleri AS (
    SELECT s.seller_id,
           s.seller_state,
           COUNT(oi.order_item_id) AS toplam_kalem_sayisi,
           SUM(oi.price + oi.freight_value) AS toplam_ciro,
           AVG(DATEDIFF(DAY, o.order_estimated_delivery_date, o.order_delivered_customer_date)) AS ort_gecikme_gun,
           AVG(r.ort_review_score) AS ort_review_score,
           AVG(p.ort_taksit_sayisi) AS ort_taksit_sayisi
    FROM sellers s
    LEFT JOIN order_items oi ON s.seller_id = oi.seller_id
    LEFT JOIN orders o ON oi.order_id = o.order_id
    LEFT JOIN cte_reviews r ON oi.order_id = r.order_id
    LEFT JOIN cte_payments p ON oi.order_id = p.order_id
    GROUP BY s.seller_id, s.seller_state
),
normalize_edilmis AS (
    SELECT *,
           (ort_taksit_sayisi - MIN(ort_taksit_sayisi) OVER ()) 
             / NULLIF(MAX(ort_taksit_sayisi) OVER () - MIN(ort_taksit_sayisi) OVER (), 0) AS taksit_norm,
           (ort_review_score - MIN(ort_review_score) OVER ()) 
             / NULLIF(MAX(ort_review_score) OVER () - MIN(ort_review_score) OVER (), 0) AS review_norm,
           (ort_gecikme_gun - MIN(ort_gecikme_gun) OVER ()) 
             / NULLIF(MAX(ort_gecikme_gun) OVER () - MIN(ort_gecikme_gun) OVER (), 0) AS gecikme_norm,
           (toplam_ciro - MIN(toplam_ciro) OVER ()) 
             / NULLIF(MAX(toplam_ciro) OVER () - MIN(toplam_ciro) OVER (), 0) AS ciro_norm
    FROM satici_metrikleri
)
SELECT seller_id,
       seller_state,
       toplam_kalem_sayisi,
       toplam_ciro,
       ort_gecikme_gun,
       ort_review_score,
       ort_taksit_sayisi,
       ROUND(
           (taksit_norm * 0.40) +
           ((1 - review_norm) * 0.30) +
           (gecikme_norm * 0.20) +
           ((1 - ciro_norm) * 0.10)
       , 3) AS risk_skoru
FROM normalize_edilmis
WHERE toplam_kalem_sayisi >= 5
ORDER BY risk_skoru DESC;