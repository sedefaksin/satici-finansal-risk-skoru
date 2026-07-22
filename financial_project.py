import pandas as pd
from sqlalchemy import create_engine
import urllib
import matplotlib.pyplot as plt
import seaborn as sns

# Bağlantı bilgisi — SQL Server Authentication değil, Windows Authentication kullanıyoruz
# (senin SSMS'te giriş yaptığın yöntemle aynı, şifre gerekmiyor)
params = urllib.parse.quote_plus(
    "DRIVER={ODBC Driver 17 for SQL Server};"
    "SERVER=localhost\\SQLEXPRESS;"
    "DATABASE=OlistDB;"
    "Trusted_Connection=yes;"
)
engine = create_engine(f"mssql+pyodbc:///?odbc_connect={params}")

# Bağlantıyı test et
print("Bağlantı başarılı" if engine else "Hata")

sorgu = """
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
SELECT seller_id, seller_state, toplam_kalem_sayisi, toplam_ciro,
       ort_gecikme_gun, ort_review_score, ort_taksit_sayisi,
       ROUND(
           (taksit_norm * 0.40) + ((1 - review_norm) * 0.30) +
           (gecikme_norm * 0.20) + ((1 - ciro_norm) * 0.10)
       , 3) AS risk_skoru
FROM normalize_edilmis
WHERE toplam_kalem_sayisi >= 5
ORDER BY risk_skoru DESC;
"""

df = pd.read_sql(sorgu, engine)
print(df.shape)      # kaç satır, kaç kolon geldi
print(df.head(10))   # ilk 10 satırı göster

korelasyon = df[['ort_taksit_sayisi', 'ort_review_score', 'ort_gecikme_gun', 'toplam_ciro', 'risk_skoru']].corr()
print(korelasyon['risk_skoru'])


plt.figure(figsize=(10, 6))
sns.histplot(df['risk_skoru'], bins=30, kde=True)
plt.title('Satıcı Risk Skoru Dağılımı')
plt.xlabel('Risk Skoru')
plt.ylabel('Satıcı Sayısı')
plt.savefig('taksit_review_riskskoru.png', dpi=300, bbox_inches='tight')
plt.show()

plt.figure(figsize=(10, 6))
sns.scatterplot(data=df, x='ort_taksit_sayisi', y='ort_review_score', hue='risk_skoru', palette='RdYlGn_r')
plt.title('Taksit Sayısı vs Review Score (Renk = Risk Skoru)')
plt.xlabel('Ortalama Taksit Sayısı')
plt.ylabel('Ortalama Review Score')
plt.savefig('taksit_review_riskskoru.png', dpi=300, bbox_inches='tight')
plt.show()