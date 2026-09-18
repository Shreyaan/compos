(function(){
var t=null;
function el(){return document.scrollingElement||document.documentElement}
addEventListener("message",function(e){
  if(e.data&&e.data.compos==="scroll"){el().scrollTop=e.data.top}
});
addEventListener("scroll",function(){
  clearTimeout(t);
  t=setTimeout(function(){
    parent.postMessage({compos:"scroll",top:Math.round(el().scrollTop)},"*")
  },250)
},true);
addEventListener("keydown",function(e){
  if(e.ctrlKey&&!e.altKey&&!e.metaKey&&e.key.toLowerCase()==="g"){
    e.preventDefault();
    e.stopImmediatePropagation();
    parent.postMessage({compos:"release"},"*")
  }
},true);
})()
