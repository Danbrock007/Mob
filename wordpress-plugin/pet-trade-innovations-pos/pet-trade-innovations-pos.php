<?php
/**
 * Plugin Name: Pet Trade Innovations POS Connector
 * Description: Secure REST connector for the Pet Trade Innovations Premium POS app.
 * Version: 1.3.0
 * Author: Muhammad Khurram Saeed / W3bco
 * Requires Plugins: woocommerce
 */

if (!defined('ABSPATH')) exit;

final class PTI_POS_Connector {
    const NS = 'pti-pos/v1';

    public static function init(): void {
        add_action('rest_api_init', [__CLASS__, 'routes']);
        add_action('admin_menu', [__CLASS__, 'menu']);
        add_action('admin_notices', [__CLASS__, 'woocommerce_notice']);
    }

    public static function woocommerce_notice(): void {
        if (!class_exists('WooCommerce')) {
            echo '<div class="notice notice-error"><p><strong>PTI POS:</strong> WooCommerce must be active.</p></div>';
        }
    }

    public static function menu(): void {
        add_menu_page('PTI Premium POS', 'PTI POS', 'manage_woocommerce', 'pti-pos', [__CLASS__, 'admin_page'], 'dashicons-store', 56);
    }

    public static function admin_page(): void {
        if (!current_user_can('manage_woocommerce')) return;
        ?>
        <div class="wrap"><h1>Pet Trade Innovations Premium POS</h1>
          <div style="max-width:850px;background:#fff;padding:24px;border:1px solid #dcdcde;border-radius:12px">
            <p><strong>Version:</strong> 1.3.0</p>
            <p><strong>Website URL:</strong> <?php echo esc_html(home_url()); ?></p>
            <p><strong>API Base:</strong> <code><?php echo esc_html(rest_url(self::NS)); ?></code></p>
            <p>Create an Application Password under <strong>Users → Profile</strong> using the name <code>PTI Premium POS App</code>.</p>
          </div>
        </div>
        <?php
    }

    public static function routes(): void {
        register_rest_route(self::NS, '/me', ['methods'=>'GET','callback'=>[__CLASS__,'me'],'permission_callback'=>[__CLASS__,'can_view']]);
        register_rest_route(self::NS, '/dashboard', ['methods'=>'GET','callback'=>[__CLASS__,'dashboard'],'permission_callback'=>[__CLASS__,'can_view']]);
        register_rest_route(self::NS, '/orders', [
            ['methods'=>'GET','callback'=>[__CLASS__,'orders'],'permission_callback'=>[__CLASS__,'can_view']],
            ['methods'=>'POST','callback'=>[__CLASS__,'create_order'],'permission_callback'=>[__CLASS__,'can_edit']],
        ]);
        register_rest_route(self::NS, '/orders/(?P<id>\d+)', [
            ['methods'=>'GET','callback'=>[__CLASS__,'order'],'permission_callback'=>[__CLASS__,'can_view']],
            ['methods'=>'PATCH','callback'=>[__CLASS__,'update_order'],'permission_callback'=>[__CLASS__,'can_edit']],
        ]);
        register_rest_route(self::NS, '/products', [
            ['methods'=>'GET','callback'=>[__CLASS__,'products'],'permission_callback'=>[__CLASS__,'can_view']],
            ['methods'=>'POST','callback'=>[__CLASS__,'create_product'],'permission_callback'=>[__CLASS__,'can_edit']],
        ]);
        register_rest_route(self::NS, '/products/(?P<id>\d+)', [
            ['methods'=>'GET','callback'=>[__CLASS__,'product'],'permission_callback'=>[__CLASS__,'can_view']],
            ['methods'=>'PATCH','callback'=>[__CLASS__,'update_product'],'permission_callback'=>[__CLASS__,'can_edit']],
        ]);
        register_rest_route(self::NS, '/customers', ['methods'=>'GET','callback'=>[__CLASS__,'customers'],'permission_callback'=>[__CLASS__,'can_view']]);
        register_rest_route(self::NS, '/payment-gateways', ['methods'=>'GET','callback'=>[__CLASS__,'payment_gateways'],'permission_callback'=>[__CLASS__,'can_view']]);
        register_rest_route(self::NS, '/media', ['methods'=>'POST','callback'=>[__CLASS__,'upload_media'],'permission_callback'=>[__CLASS__,'can_edit']]);
    }

    public static function can_view(): bool { return current_user_can('manage_woocommerce') || current_user_can('view_woocommerce_reports'); }
    public static function can_edit(): bool { return current_user_can('manage_woocommerce'); }
    private static function money($value): string { return wc_format_decimal($value ?: 0, wc_get_price_decimals()); }

    public static function me(): WP_REST_Response {
        $u=wp_get_current_user();
        return rest_ensure_response(['id'=>$u->ID,'name'=>$u->display_name,'email'=>$u->user_email,'currency'=>get_woocommerce_currency(),'currency_symbol'=>get_woocommerce_currency_symbol()]);
    }

    private static function range_from_request(WP_REST_Request $r): array {
        $from=sanitize_text_field((string)$r->get_param('from'));
        $to=sanitize_text_field((string)$r->get_param('to'));
        if (!$from && !$to) return [];
        if (!$from) $from='2000-01-01';
        if (!$to) $to=current_time('Y-m-d');
        return ['date_created'=>$from.' 00:00:00...'.$to.' 23:59:59'];
    }

    public static function dashboard(WP_REST_Request $r): WP_REST_Response {
        $range=self::range_from_request($r);
        $args=array_merge(['limit'=>-1,'return'=>'objects'], $range);
        $orders=wc_get_orders($args);
        $sales=0.0; $valid=0; $completed=0; $refunded=0; $pending=0;
        foreach($orders as $o){
            $status=$o->get_status();
            if($status==='completed') $completed++;
            if($status==='refunded') $refunded++;
            if(in_array($status,['pending','processing','on-hold'],true)) $pending++;
            if(!in_array($status,['cancelled','failed','refunded'],true)){ $sales+=(float)$o->get_total(); $valid++; }
        }
        $open=wc_get_orders(['status'=>['pending','processing','on-hold'],'limit'=>1,'paginate'=>true]);
        $low=0; $threshold=(int)get_option('woocommerce_notify_low_stock_amount',2);
        foreach(wc_get_products(['limit'=>-1,'return'=>'ids','stock_status'=>'instock']) as $id){
            $p=wc_get_product($id);
            if($p && $p->managing_stock() && $p->get_stock_quantity()!==null && $p->get_stock_quantity()<=$threshold) $low++;
        }
        return rest_ensure_response([
            'total_orders'=>count($orders),'total_sales'=>self::money($sales),'average_order_value'=>self::money($valid?$sales/$valid:0),
            'completed_orders'=>$completed,'refunded_orders'=>$refunded,'pending_orders'=>$pending,'open_orders'=>(int)$open->total,'low_stock'=>$low,
            'currency'=>get_woocommerce_currency(),'currency_symbol'=>get_woocommerce_currency_symbol(),
            'from'=>$r->get_param('from'),'to'=>$r->get_param('to'),
        ]);
    }

    public static function orders(WP_REST_Request $r): WP_REST_Response {
        $page=max(1,(int)($r->get_param('page')?:1));
        $per=min(100,max(1,(int)($r->get_param('per_page')?:20)));
        $query=trim(sanitize_text_field((string)$r->get_param('search')));
        $status=sanitize_text_field((string)$r->get_param('status'));
        $base=array_merge(['limit'=>-1,'orderby'=>'date','order'=>'DESC','return'=>'objects'],self::range_from_request($r));
        if($status) $base['status']=array_filter(array_map('sanitize_key',explode(',',$status)));
        $all=wc_get_orders($base);
        if($query!==''){
            $needle=mb_strtolower(ltrim($query,'#'));
            $all=array_values(array_filter($all,function($o)use($needle){
                $billing=$o->get_address('billing');
                $haystack=mb_strtolower(implode(' ',[
                    $o->get_order_number(),
                    $o->get_id(),
                    $billing['first_name']??'',
                    $billing['last_name']??'',
                    $billing['email']??'',
                    $billing['phone']??'',
                ]));
                return mb_strpos($haystack,$needle)!==false;
            }));
        }
        $total=count($all);
        $total_pages=max(1,(int)ceil($total/$per));
        if($page>$total_pages)$page=$total_pages;
        $items=array_slice($all,($page-1)*$per,$per);
        return rest_ensure_response(['items'=>array_map([__CLASS__,'order_data'],$items),'total'=>$total,'total_pages'=>$total_pages,'page'=>$page]);
    }

    public static function order(WP_REST_Request $r) {
        $o=wc_get_order((int)$r['id']); if(!$o) return new WP_Error('pti_not_found','Order not found',['status'=>404]);
        return rest_ensure_response(self::order_data($o,true));
    }

    public static function update_order(WP_REST_Request $r) {
        $o=wc_get_order((int)$r['id']); if(!$o) return new WP_Error('pti_not_found','Order not found',['status'=>404]);
        $p=$r->get_json_params();
        if(isset($p['status'])){
            $status=sanitize_key($p['status']);
            if(!array_key_exists('wc-'.$status,wc_get_order_statuses())) return new WP_Error('pti_bad_status','Invalid order status',['status'=>400]);
            $o->update_status($status,'Updated from PTI Premium POS',true);
        }
        if(!empty($p['note'])) $o->add_order_note(sanitize_textarea_field($p['note']),false,true);
        $o->save(); return rest_ensure_response(self::order_data($o,true));
    }

    public static function create_order(WP_REST_Request $r) {
        $p=$r->get_json_params(); $items=$p['line_items']??$p['items']??[];
        if(empty($items)||!is_array($items)) return new WP_Error('pti_no_items','At least one item is required',['status'=>400]);
        $o=wc_create_order();
        foreach($items as $line){$product=wc_get_product((int)($line['product_id']??0));if($product)$o->add_product($product,max(1,(int)($line['quantity']??1)));}
        if(!$o->get_items()){$o->delete(true);return new WP_Error('pti_invalid_items','No valid products supplied',['status'=>400]);}
        $billing=is_array($p['billing']??null)?$p['billing']:[];
        if(!$billing){$name=sanitize_text_field($p['customer_name']??'Walk-in Customer');$parts=preg_split('/\s+/',trim($name),2);$billing=['first_name'=>$parts[0]??'Walk-in','last_name'=>$parts[1]??'Customer'];}
        $safe=[];
        foreach(['first_name','last_name','company','address_1','address_2','city','state','postcode','country','email','phone'] as $key){if(isset($billing[$key]))$safe[$key]=sanitize_text_field($billing[$key]);}
        $o->set_address($safe,'billing');
        if(!empty($p['shipping'])&&is_array($p['shipping'])){$ship=[];foreach(['first_name','last_name','company','address_1','address_2','city','state','postcode','country'] as $key){if(isset($p['shipping'][$key]))$ship[$key]=sanitize_text_field($p['shipping'][$key]);}$o->set_address($ship,'shipping');}
        $gateway_id=sanitize_key($p['payment_method']??'cod');
        $gateways=WC()->payment_gateways()->payment_gateways();
        if(isset($gateways[$gateway_id])){$o->set_payment_method($gateways[$gateway_id]);}else{$o->set_payment_method($gateway_id);$o->set_payment_method_title(strtoupper($gateway_id));}
        if(!empty($p['customer_note']))$o->set_customer_note(sanitize_textarea_field($p['customer_note']));
        $o->update_meta_data('_wc_order_attribution_source_type','admin');
        $o->update_meta_data('_wc_order_attribution_utm_source','PTI POS');
        $o->calculate_totals();$o->save();$o->update_status('processing','Created from PTI Premium POS',true);
        return new WP_REST_Response(self::order_data($o,true),201);
    }

    private static function source_data(WC_Order $o): array {
        $source=(string)$o->get_meta('_wc_order_attribution_utm_source');
        $medium=(string)$o->get_meta('_wc_order_attribution_utm_medium');
        $campaign=(string)$o->get_meta('_wc_order_attribution_utm_campaign');
        $type=(string)$o->get_meta('_wc_order_attribution_source_type');
        $origin=(string)$o->get_meta('_wc_order_attribution_referrer');
        if(!$source) $source=(string)$o->get_meta('_order_source');
        if(!$source && $type==='organic') $source='Organic';
        if(!$source && $type==='direct') $source='Direct';
        if(!$source && $origin){ $host=wp_parse_url($origin,PHP_URL_HOST); $source=$host?:$origin; }
        if(!$source) $source='Unknown';
        return ['source'=>$source,'medium'=>$medium,'campaign'=>$campaign,'source_type'=>$type,'referrer'=>$origin];
    }

    private static function order_data(WC_Order $o,bool $full=false): array {
        $billing=$o->get_address('billing'); $shipping=$o->get_address('shipping'); $source=self::source_data($o);
        $data=[
            'id'=>$o->get_id(),'number'=>$o->get_order_number(),'status'=>$o->get_status(),
            'date_created'=>$o->get_date_created()?$o->get_date_created()->date(DATE_ATOM):null,
            'total'=>self::money($o->get_total()),'subtotal'=>self::money($o->get_subtotal()),'shipping_total'=>self::money($o->get_shipping_total()),'discount_total'=>self::money($o->get_discount_total()),
            'currency'=>$o->get_currency(),'currency_symbol'=>get_woocommerce_currency_symbol($o->get_currency()),
            'payment_method'=>$o->get_payment_method_title(),'customer_name'=>trim(($billing['first_name']??'').' '.($billing['last_name']??'')),
            'phone'=>$billing['phone']??'','email'=>$billing['email']??'','item_count'=>$o->get_item_count(),
            'source'=>$source['source'],'source_medium'=>$source['medium'],'source_campaign'=>$source['campaign'],'source_type'=>$source['source_type'],'source_referrer'=>$source['referrer'],
        ];
        if($full){
            $data['billing']=$billing; $data['shipping']=$shipping; $data['customer_note']=$o->get_customer_note(); $lines=[];
            foreach($o->get_items() as $item){$p=$item->get_product();$lines[]=['product_id'=>$item->get_product_id(),'variation_id'=>$item->get_variation_id(),'name'=>$item->get_name(),'quantity'=>$item->get_quantity(),'subtotal'=>self::money($item->get_subtotal()),'total'=>self::money($item->get_total()),'image'=>$p?wp_get_attachment_image_url($p->get_image_id(),'thumbnail'):null];}
            $data['items']=$lines; $data['line_items']=$lines;
        }
        return $data;
    }

    public static function products(WP_REST_Request $r): WP_REST_Response {
        $page=max(1,(int)($r->get_param('page')?:1)); $per=min(100,max(1,(int)($r->get_param('per_page')?:30)));
        $args=['limit'=>$per,'page'=>$page,'paginate'=>true,'orderby'=>'date','order'=>'DESC','status'=>['publish','private','draft']];
        if($q=sanitize_text_field((string)$r->get_param('search'))) $args['search']='*'.$q.'*';
        $res=wc_get_products($args);
        return rest_ensure_response(['items'=>array_map([__CLASS__,'product_data'],$res->products),'total'=>(int)$res->total,'total_pages'=>(int)$res->max_num_pages,'page'=>$page]);
    }

    public static function product(WP_REST_Request $r) { $p=wc_get_product((int)$r['id']); if(!$p)return new WP_Error('pti_not_found','Product not found',['status'=>404]); return rest_ensure_response(self::product_data($p,true)); }

    private static function apply_product_data(WC_Product $p,array $d): void {
        if(isset($d['name'])) $p->set_name(sanitize_text_field($d['name']));
        if(isset($d['status']) && in_array($d['status'],['publish','draft','private'],true)) $p->set_status($d['status']);
        if(array_key_exists('regular_price',$d)) $p->set_regular_price($d['regular_price']===''?'':wc_format_decimal($d['regular_price']));
        if(array_key_exists('sale_price',$d)) $p->set_sale_price($d['sale_price']===''?'':wc_format_decimal($d['sale_price']));
        if(isset($d['manage_stock'])) $p->set_manage_stock((bool)$d['manage_stock']);
        if(array_key_exists('stock_quantity',$d) && $d['stock_quantity']!==null){$p->set_manage_stock(true);$p->set_stock_quantity((int)$d['stock_quantity']);}
        if(isset($d['stock_status']) && in_array($d['stock_status'],['instock','outofstock','onbackorder'],true)) $p->set_stock_status($d['stock_status']);
        if(isset($d['sku'])) $p->set_sku(sanitize_text_field($d['sku']));
        if(isset($d['description'])) $p->set_description(wp_kses_post($d['description']));
        if(isset($d['short_description'])) $p->set_short_description(wp_kses_post($d['short_description']));
        if(!empty($d['image'])){$id=attachment_url_to_postid(esc_url_raw($d['image']));if($id)$p->set_image_id($id);}
        if(isset($d['gallery'])&&is_array($d['gallery'])){$ids=[];foreach($d['gallery'] as $entry){$url=is_array($entry)?($entry['src']??''):$entry;$id=attachment_url_to_postid(esc_url_raw($url));if($id)$ids[]=$id;}$p->set_gallery_image_ids($ids);}
        if(isset($d['category_ids'])&&is_array($d['category_ids'])) $p->set_category_ids(array_map('intval',$d['category_ids']));
    }

    public static function create_product(WP_REST_Request $r) {
        $d=$r->get_json_params(); if(empty($d['name'])) return new WP_Error('pti_name_required','Product name is required',['status'=>400]);
        $p=new WC_Product_Simple(); self::apply_product_data($p,$d); if(!$p->get_status())$p->set_status('publish'); $id=$p->save();
        return new WP_REST_Response(self::product_data(wc_get_product($id),true),201);
    }

    public static function update_product(WP_REST_Request $r) {
        $p=wc_get_product((int)$r['id']); if(!$p)return new WP_Error('pti_not_found','Product not found',['status'=>404]); self::apply_product_data($p,$r->get_json_params()); $p->save(); return rest_ensure_response(self::product_data($p,true));
    }

    private static function product_data(WC_Product $p,bool $full=false): array {
        return ['id'=>$p->get_id(),'name'=>$p->get_name(),'type'=>$p->get_type(),'sku'=>$p->get_sku(),'price'=>self::money($p->get_price()),'regular_price'=>self::money($p->get_regular_price()),'sale_price'=>$p->get_sale_price()===''?'':self::money($p->get_sale_price()),'manage_stock'=>$p->managing_stock(),'stock_quantity'=>$p->get_stock_quantity(),'stock_status'=>$p->get_stock_status(),'image'=>wp_get_attachment_image_url($p->get_image_id(),'medium'),'status'=>$p->get_status(),'currency_symbol'=>get_woocommerce_currency_symbol(),'description'=>$p->get_description(),'short_description'=>$p->get_short_description(),'gallery'=>array_values(array_filter(array_map(function($id){$url=wp_get_attachment_image_url($id,'large');return $url?['id'=>$id,'src'=>$url]:null;},$p->get_gallery_image_ids())))];
    }

    public static function customers(WP_REST_Request $r): WP_REST_Response {
        $q=sanitize_text_field((string)$r->get_param('search')); $page=max(1,(int)($r->get_param('page')?:1)); $per=min(100,max(1,(int)($r->get_param('per_page')?:20)));
        $args=['role__in'=>['customer','subscriber'],'number'=>$per,'offset'=>($page-1)*$per,'orderby'=>'registered','order'=>'DESC','count_total'=>true]; if($q)$args['search']='*'.$q.'*';
        $query=new WP_User_Query($args); $out=[]; foreach($query->get_results() as $u){$out[]=['id'=>$u->ID,'name'=>$u->display_name,'email'=>$u->user_email,'phone'=>get_user_meta($u->ID,'billing_phone',true),'orders_count'=>(int)wc_get_customer_order_count($u->ID),'total_spent'=>self::money(wc_get_customer_total_spent($u->ID))];}
        $total=(int)$query->get_total(); return rest_ensure_response(['items'=>$out,'total'=>$total,'page'=>$page,'total_pages'=>(int)ceil($total/$per)]);
    }

    public static function payment_gateways(): WP_REST_Response {
        $items=[];
        foreach(WC()->payment_gateways()->payment_gateways() as $id=>$gateway){
            if($gateway->enabled==='yes'||in_array($id,['cod','bacs'],true))$items[]=['id'=>$id,'title'=>$gateway->get_title()?:$gateway->get_method_title(),'description'=>wp_strip_all_tags($gateway->get_description())];
        }
        if(!$items)$items=[['id'=>'cod','title'=>'Cash on delivery','description'=>'']];
        return rest_ensure_response(['items'=>$items]);
    }

    public static function upload_media(WP_REST_Request $r) {
        if(empty($_FILES['file'])) return new WP_Error('pti_no_file','No file uploaded',['status'=>400]);
        require_once ABSPATH.'wp-admin/includes/file.php'; require_once ABSPATH.'wp-admin/includes/media.php'; require_once ABSPATH.'wp-admin/includes/image.php';
        $id=media_handle_upload('file',0); if(is_wp_error($id))return $id; return new WP_REST_Response(['id'=>$id,'url'=>wp_get_attachment_url($id),'source_url'=>wp_get_attachment_url($id)],201);
    }
}
PTI_POS_Connector::init();
