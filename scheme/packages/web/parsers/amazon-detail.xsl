<?xml version="1.0" encoding="UTF-8"?>
<!-- One Amazon product page as a record.

     amazon-rows.xsl reads the search listing; this one reads the page a
     row points at, where the real detail is: the About-this-item bullets,
     the two specification tables, the star histogram and the first page
     of reviews Amazon prints on the product page itself.

     It emits one JSON object, not an array, so json-parse hands Scheme a
     single plist whose specs, bullets and reviews are nested lists.

     The reviews are the eight the page ships with; each one is repeated
     inside its own media-popover modal, so every per-review select is
     parenthesised and taken at [1]: document order, the real copy. -->
<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
  <xsl:output method="text" encoding="UTF-8" omit-xml-declaration="yes"/>
  <xsl:strip-space elements="*"/>

  <!-- JSON string escaping: backslash first, then quote. -->
  <xsl:template name="esc-bs">
    <xsl:param name="s"/>
    <xsl:choose>
      <xsl:when test="contains($s, '\')">
        <xsl:value-of select="substring-before($s, '\')"/>
        <xsl:text>\\</xsl:text>
        <xsl:call-template name="esc-bs">
          <xsl:with-param name="s" select="substring-after($s, '\')"/>
        </xsl:call-template>
      </xsl:when>
      <xsl:otherwise><xsl:value-of select="$s"/></xsl:otherwise>
    </xsl:choose>
  </xsl:template>

  <xsl:template name="esc">
    <xsl:param name="s"/>
    <xsl:choose>
      <xsl:when test="contains($s, '&quot;')">
        <xsl:call-template name="esc-bs">
          <xsl:with-param name="s" select="substring-before($s, '&quot;')"/>
        </xsl:call-template>
        <xsl:text>\&quot;</xsl:text>
        <xsl:call-template name="esc">
          <xsl:with-param name="s" select="substring-after($s, '&quot;')"/>
        </xsl:call-template>
      </xsl:when>
      <xsl:otherwise>
        <xsl:call-template name="esc-bs">
          <xsl:with-param name="s" select="$s"/>
        </xsl:call-template>
      </xsl:otherwise>
    </xsl:choose>
  </xsl:template>

  <!-- a bare JSON string -->
  <xsl:template name="str">
    <xsl:param name="val"/>
    <xsl:text>&quot;</xsl:text>
    <xsl:call-template name="esc">
      <xsl:with-param name="s" select="normalize-space($val)"/>
    </xsl:call-template>
    <xsl:text>&quot;</xsl:text>
  </xsl:template>

  <!-- "key":"value" -->
  <xsl:template name="field">
    <xsl:param name="key"/>
    <xsl:param name="val"/>
    <xsl:text>&quot;</xsl:text>
    <xsl:value-of select="$key"/>
    <xsl:text>&quot;:</xsl:text>
    <xsl:call-template name="str">
      <xsl:with-param name="val" select="$val"/>
    </xsl:call-template>
  </xsl:template>

  <!-- {"k":..,"v":..} for one row of a specification table -->
  <xsl:template name="pair">
    <xsl:param name="k"/>
    <xsl:param name="v"/>
    <xsl:text>{</xsl:text>
    <xsl:call-template name="field">
      <xsl:with-param name="key" select="'k'"/>
      <xsl:with-param name="val" select="$k"/>
    </xsl:call-template>
    <xsl:text>,</xsl:text>
    <xsl:call-template name="field">
      <xsl:with-param name="key" select="'v'"/>
      <xsl:with-param name="val" select="$v"/>
    </xsl:call-template>
    <xsl:text>}</xsl:text>
  </xsl:template>

  <xsl:template match="/">
    <xsl:text>{</xsl:text>

    <xsl:call-template name="field">
      <xsl:with-param name="key" select="'title'"/>
      <xsl:with-param name="val" select="//span[@id='productTitle'][1]"/>
    </xsl:call-template>
    <xsl:text>,</xsl:text>
    <xsl:call-template name="field">
      <xsl:with-param name="key" select="'brand'"/>
      <xsl:with-param name="val" select="//a[@id='bylineInfo'][1]"/>
    </xsl:call-template>
    <xsl:text>,</xsl:text>
    <xsl:call-template name="field">
      <xsl:with-param name="key" select="'price'"/>
      <xsl:with-param name="val" select="(//div[@id='corePriceDisplay_desktop_feature_div']//span[contains(@class,'a-price-whole')])[1]"/>
    </xsl:call-template>
    <xsl:text>,</xsl:text>
    <xsl:call-template name="field">
      <xsl:with-param name="key" select="'mrp'"/>
      <xsl:with-param name="val" select="(//div[@id='corePriceDisplay_desktop_feature_div']//span[contains(@class,'a-text-price')]//span[contains(@class,'a-offscreen')])[1]"/>
    </xsl:call-template>
    <xsl:text>,</xsl:text>
    <xsl:call-template name="field">
      <xsl:with-param name="key" select="'discount'"/>
      <xsl:with-param name="val" select="(//div[@id='corePriceDisplay_desktop_feature_div']//span[contains(@class,'savingsPercentage')])[1]"/>
    </xsl:call-template>
    <xsl:text>,</xsl:text>
    <xsl:call-template name="field">
      <xsl:with-param name="key" select="'availability'"/>
      <xsl:with-param name="val" select="//div[@id='availability'][1]"/>
    </xsl:call-template>
    <xsl:text>,</xsl:text>
    <xsl:call-template name="field">
      <xsl:with-param name="key" select="'delivery'"/>
      <xsl:with-param name="val" select="//div[@id='deliveryBlockMessage'][1]"/>
    </xsl:call-template>
    <xsl:text>,</xsl:text>
    <xsl:call-template name="field">
      <xsl:with-param name="key" select="'seller'"/>
      <xsl:with-param name="val" select="(//div[@id='merchantInfoFeature_feature_div']//span[contains(@class,'offer-display-feature-text-message')])[1]"/>
    </xsl:call-template>
    <xsl:text>,</xsl:text>
    <xsl:call-template name="field">
      <xsl:with-param name="key" select="'rating'"/>
      <xsl:with-param name="val" select="(//span[@id='acrPopover'])[1]/@title"/>
    </xsl:call-template>
    <xsl:text>,</xsl:text>
    <xsl:call-template name="field">
      <xsl:with-param name="key" select="'reviewCount'"/>
      <xsl:with-param name="val" select="//span[@id='acrCustomerReviewText'][1]"/>
    </xsl:call-template>
    <xsl:text>,</xsl:text>
    <xsl:call-template name="field">
      <xsl:with-param name="key" select="'description'"/>
      <xsl:with-param name="val" select="//div[@id='productDescription'][1]"/>
    </xsl:call-template>

    <xsl:text>,&quot;descParas&quot;:[</xsl:text>
    <xsl:for-each select="//div[@id='productDescription']//p">
      <xsl:if test="position() &gt; 1"><xsl:text>,</xsl:text></xsl:if>
      <xsl:call-template name="str">
        <xsl:with-param name="val" select="."/>
      </xsl:call-template>
    </xsl:for-each>
    <xsl:text>]</xsl:text>

    <!-- About this item -->
    <xsl:text>,&quot;bullets&quot;:[</xsl:text>
    <xsl:for-each select="//div[@id='feature-bullets']//li//span[contains(concat(' ', @class, ' '), ' a-list-item ')]">
      <xsl:if test="position() &gt; 1"><xsl:text>,</xsl:text></xsl:if>
      <xsl:call-template name="str">
        <xsl:with-param name="val" select="."/>
      </xsl:call-template>
    </xsl:for-each>
    <xsl:text>]</xsl:text>

    <!-- the summary table Amazon prints beside the photo -->
    <xsl:text>,&quot;overview&quot;:[</xsl:text>
    <xsl:for-each select="//div[@id='poExpander']//tr[td]">
      <xsl:if test="position() &gt; 1"><xsl:text>,</xsl:text></xsl:if>
      <xsl:call-template name="pair">
        <xsl:with-param name="k" select="td[1]"/>
        <xsl:with-param name="v" select="td[2]"/>
      </xsl:call-template>
    </xsl:for-each>
    <xsl:text>]</xsl:text>

    <!-- every technical-details and additional-information row -->
    <xsl:text>,&quot;specs&quot;:[</xsl:text>
    <xsl:for-each select="//table[contains(@class,'prodDetTable')]//tr[th][td]">
      <xsl:if test="position() &gt; 1"><xsl:text>,</xsl:text></xsl:if>
      <xsl:call-template name="pair">
        <xsl:with-param name="k" select="th[1]"/>
        <xsl:with-param name="v" select="td[1]"/>
      </xsl:call-template>
    </xsl:for-each>
    <xsl:text>]</xsl:text>

    <!-- five stars to one; the widget repeats the column per row, so the
         first five percentages are the whole histogram -->
    <xsl:text>,&quot;histogram&quot;:[</xsl:text>
    <xsl:for-each select="//span[contains(@class,'histogram-column-space')][contains(., '%')]">
      <xsl:if test="position() &lt; 6">
        <xsl:if test="position() &gt; 1"><xsl:text>,</xsl:text></xsl:if>
        <xsl:call-template name="str">
          <xsl:with-param name="val" select="."/>
        </xsl:call-template>
      </xsl:if>
    </xsl:for-each>
    <xsl:text>]</xsl:text>

    <!-- the first page of reviews, as the product page prints them -->
    <xsl:text>,&quot;reviews&quot;:[</xsl:text>
    <xsl:for-each select="//div[@data-hook='review']">
      <xsl:if test="position() &gt; 1"><xsl:text>,</xsl:text></xsl:if>
      <xsl:text>{</xsl:text>
      <xsl:call-template name="field">
        <xsl:with-param name="key" select="'author'"/>
        <xsl:with-param name="val" select="(.//span[contains(concat(' ', @class, ' '), ' a-profile-name ')])[1]"/>
      </xsl:call-template>
      <xsl:text>,</xsl:text>
      <xsl:call-template name="field">
        <xsl:with-param name="key" select="'stars'"/>
        <xsl:with-param name="val" select="(.//i[@data-hook='review-star-rating'])[1]"/>
      </xsl:call-template>
      <xsl:text>,</xsl:text>
      <xsl:call-template name="field">
        <xsl:with-param name="key" select="'title'"/>
        <xsl:with-param name="val" select="(.//*[@data-hook='reviewTitle'])[1]"/>
      </xsl:call-template>
      <xsl:text>,</xsl:text>
      <xsl:call-template name="field">
        <xsl:with-param name="key" select="'date'"/>
        <xsl:with-param name="val" select="(.//span[@data-hook='review-date'])[1]"/>
      </xsl:call-template>
      <xsl:text>,</xsl:text>
      <xsl:text>&quot;variant&quot;:[</xsl:text>
      <xsl:for-each select="(.//a[@data-hook='format-strip'])[1]/span">
        <xsl:if test="position() &gt; 1"><xsl:text>,</xsl:text></xsl:if>
        <xsl:call-template name="str">
          <xsl:with-param name="val" select="."/>
        </xsl:call-template>
      </xsl:for-each>
      <xsl:text>]</xsl:text>
      <xsl:text>,</xsl:text>
      <xsl:call-template name="field">
        <xsl:with-param name="key" select="'verified'"/>
        <xsl:with-param name="val" select="(.//span[@data-hook='avp-badge'])[1]"/>
      </xsl:call-template>
      <xsl:text>,</xsl:text>
      <xsl:call-template name="field">
        <xsl:with-param name="key" select="'helpful'"/>
        <xsl:with-param name="val" select="(.//span[@data-hook='helpful-vote-statement'])[1]"/>
      </xsl:call-template>
      <xsl:text>,</xsl:text>
      <xsl:call-template name="field">
        <xsl:with-param name="key" select="'body'"/>
        <xsl:with-param name="val" select="(.//div[@data-hook='reviewRichContentContainer'])[1]"/>
      </xsl:call-template>
      <!-- the same body as its paragraphs: normalize-space runs them
           together, and a review reads as the writer broke it -->
      <xsl:text>,&quot;paras&quot;:[</xsl:text>
      <xsl:for-each select="(.//div[@data-hook='reviewRichContentContainer'])[1]//p">
        <xsl:if test="position() &gt; 1"><xsl:text>,</xsl:text></xsl:if>
        <xsl:call-template name="str">
          <xsl:with-param name="val" select="."/>
        </xsl:call-template>
      </xsl:for-each>
      <xsl:text>]</xsl:text>
      <xsl:text>}</xsl:text>
    </xsl:for-each>
    <xsl:text>]</xsl:text>

    <xsl:text>}</xsl:text>
  </xsl:template>
</xsl:stylesheet>
